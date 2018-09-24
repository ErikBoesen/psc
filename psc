#!/usr/bin/env python3
import argparse
import os
import re
import yaml
import stat
import sys
import requests
from bs4 import BeautifulSoup
# For hashing password
import hmac, hashlib, base64
# TODO: Find alternative in existing imports
from lxml import html
from termcolor import colored

parser = argparse.ArgumentParser(description='View PowerSchool grades from the command line.')
# TODO: Implement course grade viewing
parser.add_argument('-p', dest='period', help='Period of course to view assignment grades from')
parser.add_argument('-m', dest='marking_period', help='Marking period of course to view assignment grades from')
parser.add_argument('--html', default=False, action='store_true', help='Print raw HTML being parsed')
parser.add_argument('--debug', default=False, action='store_true', help='Output debug information')
parser.add_argument('--no-color', default=False, action='store_true', help='Disable colors (UNIMPLEMENTED)')
args = parser.parse_args()

CREDENTIALS_PATH = os.path.expanduser('~') + '/.psc_credentials.yml'
credentials = {
    'username': '',
    'password': '',
}
if os.path.isfile(CREDENTIALS_PATH) and os.path.getsize(CREDENTIALS_PATH) is not 0:
    with open(CREDENTIALS_PATH, 'r') as f:
        credentials = yaml.load(f)
else:
    credentials['username'] = input('username: ')
    from getpass import getpass
    credentials['password'] = getpass('password: ')
    with open(CREDENTIALS_PATH, 'w') as f:
        yaml.dump(credentials, f)
    os.chmod(CREDENTIALS_PATH, stat.S_IRUSR | stat.S_IWUSR)

# Check if group or public can read config and the private details therein.
# If so, warn user.
if os.stat(CREDENTIALS_PATH).st_mode & (stat.S_IRGRP | stat.S_IROTH):
    print('Warning: config file may be accessible by other users.', file=sys.stderr)

CONFIG_PATH = os.path.expanduser('~') + '/.psc.yml'
config = {
    # Such as ps.fccps.org
    'host': '',
    # Additional, nonessential properties will be added later if generating config.
}
if os.path.isfile(CONFIG_PATH) and os.path.getsize(CONFIG_PATH) is not 0:
    with open(CONFIG_PATH, 'r') as f:
        config = yaml.load(f)
else:
    config = {key: input(key + ': ') for key in config.keys()}
    config.update({
        # For example, HR and DA
        'ignored_periods': [],
        'ignored_marking_periods': [],
        'remove_empty_marking_periods': False,
        'remove_redundant_semester': True,
        'colors': {
            'header': 'grey',
            'course_name': 'cyan',
            'high_grade': 'on_green',
            'medium_grade': 'on_yellow',
            'low_grade': 'on_red',
        },
        'thresholds': {
            'high': 95,
            'medium': 90,
        },
    })
    with open(CONFIG_PATH, 'w') as f:
        yaml.dump(config, f)

class PowerSchool:
    session = requests.Session()

    host: str
    username: str
    password: str

    driver = None

    def __init__(self, host, username, password):
        self.host = host
        self.username = username
        self.password = password

        login_url = 'https://' + self.host + '/guardian/home.html'
        login_page = self.session.get(login_url)
        login_tree = html.fromstring(login_page.text)
        token = list(set(login_tree.xpath('//*[@id=\'LoginForm\']/input[1]/@value')))[0]
        context_data = list(set(login_tree.xpath('//input[@id=\'contextData\']/@value')))[0]
        password_hash = hmac.new(context_data.encode('ascii'),
                                 base64.b64encode(hashlib.md5(self.password.encode('ascii')).digest()).replace(b'=', b''),
                                 hashlib.md5).hexdigest()

        payload = {
            'pstoken': token,
            'contextData': context_data,
            'dbpw': password_hash,
            'ldappassword': self.password,
            'account': self.username,
            'pw': self.password,
        }
        content = self.session.post(login_url, data=payload).content

        bs = BeautifulSoup(content, 'lxml')
        if args.html:
            print(bs.prettify())
        table = bs.find('table', class_='linkDescList grid')
        rows = table.find_all('tr')

        # TODO: This entire parsing system is finnicky and could break at the slightest change to PowerSchool's table layout.
        # Ideally we should do this in some more consistent way.
        # For now though, this is all we can do.
        # TL;DR: If you're making a widely-used web service, MAKE A UNIVERSALLY ACCESSIBLE API.

        # Remove unnecessary "Attendance by Class" header
        rows.pop(0)
        # Remove closing "Attendance Totals" row
        rows.pop()

        # While the table headers are intuitive when displayed in a browser, they're actually ordered strangely in the raw HTML.
        header = rows.pop(0)
        header_cells = header.find_all('th')
        titles = [cell.text for cell in header_cells[:4] + header_cells[-2:]]
        marking_periods = [cell.text for cell in header_cells[4:-2]]
        used_marking_periods = set()
        # TODO: Clean up confusing naming
        days = []
        for day in rows.pop(0).find_all('th'):
            if day.text not in days:
                days.append(day.text)

        courses = []
        for row in rows:
            course = {}
            cells = row.find_all('td')
            # TODO: Clean all periods at end?
            # Store period name
            course[titles[0]] = self._clean_period(cells.pop(0).text)
            # Store Last Week and This Week attendance
            course[titles[1]] = {day: cells.pop(0).text.strip() for day in days}
            course[titles[2]] = {day: cells.pop(0).text.strip() for day in days}
            # Deal with course title, teacher, etc.
            course_cell = cells.pop(0)
            # Get name of course
            course[titles[3]] = course_cell.find('br').previousSibling.strip()
            links = course_cell.find_all('a')
            course['Teacher'] = links.pop(0).text[len('Details about '):]
            course['Teacher Email'] = links[0]['href'][len('mailto:'):]
            course['Room'] = links[0].nextSibling[len('\xa0-\xa0Rm: '):]

            course['Letter Grades'] = {}
            course['Grades'] = {}
            for marking_period in marking_periods:
                grade_cell = cells.pop(0)
                if grade_cell.find('a'):
                    course_id = grade_cell.find('a')['href'].strip('scores.html?frn=')
                    course_id = course_id[:course_id.find('&')]
                    course['ID'] = course_id
                # If no grade is in yet, put it in empty.
                raw = self._clean_grade(grade_cell.text.strip())
                if not raw:
                    # TODO: It would be better to set them to None than to an empty string...
                    course['Letter Grades'][marking_period] = course['Grades'][marking_period] = raw
                else:
                    used_marking_periods.add(marking_period)
                    course['Letter Grades'][marking_period] = grade_cell.find('br').previousSibling.strip()
                    course['Grades'][marking_period] = int(grade_cell.find('br').nextSibling.strip().strip('%'))

            # Absences and Tardies
            # TODO: Throw if the headers are wrong
            course[titles[4]] = cells.pop(0).text
            course[titles[5]] = cells.pop(0).text

            # Debug
            """for i, cell in enumerate(cells):
                print(cell.text, end=' ')
            print()"""
            courses.append(course)

        if args.debug:
            print(titles)
            print(marking_periods)
            print(used_marking_periods)
            print(days)
            print(courses)

        self.titles = titles
        self.marking_periods = marking_periods
        self.used_marking_periods = used_marking_periods
        self.days = days
        self.courses = courses

    def _clean_period(self, string: str) -> str:
        # TODO: Make optional
        end = string.find('(')
        if end < 0:
            return string
        else:
            return string[:end]

    def _clean_grade(self, string: str) -> str:
        """
        Clean nonsense from grade output.
        """
        if string in ['[ i ]']:
            return ''
        else:
            return string

    def _render_attendance(self, string: str) -> str:
        short = string[0] if string else ' '
        if string == ' ':
            return short
        elif string in ['.', '-']:
            color = 'grey'
        elif string in ['ISS', 'OFFICE', 'OSS', 'TRU', 'TUN', 'UNV', 'UNX']:
            color = 'red'
        else:
            color = 'green'
        return colored(short, color)

    def print_grades(self):
        titles = self.titles
        marking_periods = self.marking_periods
        used_marking_periods = self.used_marking_periods
        days = self.days
        courses = self.courses

        # Remove ignored marking periods from grade list
        if config['remove_empty_marking_periods']:
            marking_periods = sorted(list(used_marking_periods), key=lambda marking_period: marking_periods.index(marking_period))
        marking_periods = [marking_period for marking_period in marking_periods if marking_period not in config['ignored_marking_periods']]
        if config['remove_redundant_semester']:
            # TODO: Find cleaner implementation
            if ('Q1' in marking_periods and not 'Q2' in marking_periods and 'S1' in marking_periods):
                marking_periods.remove('S1')
            if ('Q3' in marking_periods and not 'Q4' in marking_periods and 'S2' in marking_periods):
                marking_periods.remove('S2')

        # Header
        header_line = ('Per'.ljust(3) + ' ' +
                       (2 * (''.join(days) + ' ')) +
                       'Course'.ljust(30) + ' ')
        for marking_period in marking_periods:
            header_line += marking_period.ljust(6) + ' '
        header_line += 'Abs'.ljust(3) + ' ' + 'Tar'.ljust(3)
        print(header_line)
        print('-' * len(header_line))

        # Content
        for course in courses:
            if course['Exp'] in config['ignored_periods']:
                continue
            print(course['Exp'].ljust(3), end=' ')
            print(''.join([self._render_attendance(course['Last Week'][day]) for day in days]), end=' ')
            print(''.join([self._render_attendance(course['This Week'][day]) for day in days]), end=' ')
            print(colored(course['Course'].ljust(30), config['colors']['course_name']), end=' ')
            for marking_period in marking_periods:
                numerical = course['Grades'][marking_period]
                if not numerical:
                    # There's no grade in
                    print(' ' * 6, end=' ')
                else:
                    if numerical >= config['thresholds']['high']:
                        color = config['colors']['high_grade']
                    elif numerical >= config['thresholds']['medium']:
                        color = config['colors']['medium_grade']
                    else:
                        color = config['colors']['low_grade']
                    # TODO: Make sure white color supports black-on-white terminals
                    print(colored(('%s/%d' % (course['Letter Grades'][marking_period], course['Grades'][marking_period])).ljust(6), 'grey', color), end=' ')
            print(course['Absences'].ljust(3), end=' ')
            print(course['Tardies'].ljust(3), end=' ')
            print()

    def virtual_login(self):
        if not self.driver:
            from selenium import webdriver
            from selenium.webdriver.firefox.options import Options as chromeOptions
            browser_options = chromeOptions()
            browser_options.add_argument('--headless')
            self.driver = webdriver.Chrome(chrome_options=browser_options)
            self.driver.get('https://' + self.host + '/guardian/home.html')
            self.driver.find_element_by_id('fieldAccount').send_keys(self.username)
            self.driver.find_element_by_id('fieldPassword').send_keys(self.password)
            self.driver.find_element_by_id('btn-enter-sign-in').click()

    def get_course(self, period, marking_period=None):
        course = next((course for course in self.courses if course['Exp'] == period), None)
        # TODO: What does it do when you don't give a marking period?
        # THIS PROCESS IS NOT WELL POLISHED. Proceed with caution.
        course_url = 'https://' + self.host + '/guardian/scores.html?frn=' + course['ID'] + (('&fg=' + marking_period) if marking_period else '')
        self.virtual_login()
        self.driver.get(course_url)
        #raw_content = self.session.get(course_url).content
        #raw_content = self.driver.page_source
        #bs = BeautifulSoup(raw_content, 'lxml')
        #meta_table = bs.find('table', {'class': 'linkDescList'})
        meta_table = self.driver.find_element_by_id('scoreTable')
        meta_fields = meta_table.find_all('tr')[1].find_all('td')
        meta = {}
        meta['Course'] = meta_fields[0].text
        meta['Teacher'] = meta_fields[1].text
        meta['Expression'] = meta_fields[2].text
        print(raw_content)
        print(meta)
        # TODO: This is a bunch of JavaScript when it's normally _ _%. For now we will just use the stat we already have.
        #meta['Final Grade'] = meta_fields[3].text
        # Breaks when not given a marking period...
        meta['Final Grade'] = course['Grades'][marking_period]
        # TODO: you could just check if this is empty and only then get the real output then, I guess?


        # TOTALLY BROKEN
        # Seems like the assignments table is generated through JavaScript. This may be an issue...
        # TODO
        assignments_table = bs.find_all('table')
        print(assignments_table)
        assignments_tbody = assignments_table.find('tbody')
        assignments_raw = assignments_tbody.find_all('tr')
        assignments_raw.pop()
        assignments = {}
        for assignment in assignments_raw:
            cells = assignment.find_all('td')
            assignments.append({
                'Due Date': cells[0].text,
                'Category': cells[1].text,
                'Assignment': cells[2].text,
                # TODO: Implement flags
                #'Flags': cells[3].text,
                'Score': cells[4].text,
                '%': cells[5].text,
                'Grade': cells[6].text,
                # Not really sure what this column is supposed to be
                # TODO
                #'Comments': cells[7].text,
            })

        print(meta)

ps = PowerSchool(config['host'], credentials['username'], credentials['password'])
if args.period:
    ps.get_course(args.period, args.marking_period)
else:
    ps.print_grades()

"""
def getRawAssignments(p,period):
    ...
    p=s.get(href, headers = {'Accept-Encoding': 'identity'})
    data=BeautifulSoup(p.content, 'lxml')
    table=data.find('table', { 'align' : 'center' })
    tr=table.findAll('tr')
    assignments={}
    for i in range (1,len(tr)):
        td=tr[i].findAll('td')
        assignments['{}'.format(hex(i))]=createSmallAssignment(td[0].getText(),td[1].getText(),td[2].getText(),td[8].getText(),td[9].getText())
    return assignments
    return all
"""
