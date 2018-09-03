#!/usr/bin/env python3
import argparse
import os
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
parser.add_argument('-c', dest='course', nargs=1, help='Course to view assignment grades from (UNIMPLEMENTED)')
parser.add_argument('--debug', default=False, action='store_true', help='Output debug information')
parser.add_argument('--no-color', default=False, action='store_true', help='Disable colors (UNIMPLEMENTED)')
args = parser.parse_args()

CONFIG_PATH = os.path.expanduser('~') + '/.psc.yml'
config = {
    # Such as ps.fccps.org
    'host': '',
    'username': '',
    'password': '',
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
    })
    with open(CONFIG_PATH, 'w') as f:
        yaml.dump(config, f)
    os.chmod(CONFIG_PATH, stat.S_IRUSR | stat.S_IRUSR)

# Check if group or public can read config and the private details therein.
# If so, warn user.
if os.stat(CONFIG_PATH).st_mode & (stat.S_IRGRP | stat.S_IROTH):
    print('Warning: config file may be accessible by other users.', file=sys.stderr)

s = requests.Session()

login_url = 'https://' + config['host'] + '/guardian/home.html'
login_page = s.get(login_url)
login_tree = html.fromstring(login_page.text)
token = list(set(login_tree.xpath('//*[@id=\'LoginForm\']/input[1]/@value')))[0]
context_data = list(set(login_tree.xpath('//input[@id=\'contextData\']/@value')))[0]
password_hash = hmac.new(context_data.encode('ascii'),
                         base64.b64encode(hashlib.md5(config['password'].encode('ascii')).digest()).replace(b'=', b''),
                         hashlib.md5).hexdigest()

payload = {
    'pstoken': token,
    'contextData': context_data,
    'dbpw': password_hash,
    'ldappassword': config['password'],
    'account': config['username'],
    'pw': config['password'],
}
content = s.post(login_url, data=payload).content

bs = BeautifulSoup(content, 'lxml')
table = bs.find('table', class_='linkDescList grid')
rows = table.find_all('tr')
# TODO: This entire parsing system is finnicky and could break at the slightest change to PowerSchool's table layout.
# Ideally we should do this in some more consistent way.
# For now though, this is all we can do.
# TL;DR: If you're making a widely-used web service, MAKE AN API.

# Remove unnecessary "Attendance by Class" header
rows.pop(0)
# Remove closing "Attendance Totals" row
rows.pop()

# While the table headers are intuitive when displayed in a browser, they're actually ordered strangely in the raw HTML.
header = rows.pop(0)
header_cells = header.find_all('th')
titles = [cell.text for cell in header_cells[:4] + header_cells[-2:]]
grades = [cell.text for cell in header_cells[4:-2]]
# TODO: Clean up confusing naming
days = []
for day in rows.pop(0).find_all('th'):
    if day.text not in days:
        days.append(day.text)

def clean_period(string: str) -> str:
    # TODO: Make optional
    end = string.find('(')
    if end < 0:
        return string
    else:
        return string[:end]

def clean_grade(string: str) -> str:
    """
    Clean nonsense from grade output.
    """
    if string in ['[ i ]']:
        return ''
    else:
        return string

courses = []
for row in rows:
    course = {}
    cells = row.find_all('td')
    # TODO: Clean all periods at end?
    # Store period name
    course[titles[0]] = clean_period(cells.pop(0).text)
    # Store Last Week and This Week attendance
    course[titles[1]] = {day: cells.pop(0).text.strip() for day in days}
    course[titles[2]] = {day: cells.pop(0).text.strip() for day in days}
    # Deal with course title, teacher, etc.
    course_cell = cells.pop(0)
    # Get name of course
    # TODO: Better way to get rid of \xa0 than .strip()?
    course[titles[3]] = course_cell.find('br').previousSibling.strip()
    links = course_cell.find_all('a')
    course['Teacher'] = links.pop(0).text.strip('Details about ')
    course['Teacher Email'] = links[0]['href'].strip('mailto:')
    course['Room'] = links[0].nextSibling.strip(' - Rm: ')

    course['Grades'] = {}
    for grade in grades:
        # TODO: Will need to parse letter and number grade
        course['Grades'][grade] = clean_grade(cells.pop(0).text.strip())

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
    print(grades)
    print(days)
    print(courses)

# Print out table
# Helper functions
def simplify_attendance(string: str) -> str:
    return string[0] if string else ' '

# Headers
print('Per'.ljust(3), end=' ')
for _ in range(2):
    print(''.join(days), end=' ')
print('Course'.ljust(30), end=' ')
for grade in grades:
    print(grade.ljust(5), end=' ')
print('Abs'.ljust(3), end=' ')
print('Tar'.ljust(3), end=' ')
print()

# Content
for course in courses:
    if course['Exp'] in config['ignored_periods']:
        continue
    print(course['Exp'].ljust(3), end=' ')
    print(''.join([simplify_attendance(course['Last Week'][day]) for day in days]), end=' ')
    print(''.join([simplify_attendance(course['This Week'][day]) for day in days]), end=' ')
    print(course['Course'].ljust(30), end=' ')
    for grade in grades:
        print(course['Grades'][grade].ljust(5), end=' ')
    print(course['Absences'].ljust(3), end=' ')
    print(course['Tardies'].ljust(3), end=' ')
    print()


"""
def createSmallClass(teacher, grade):
    data={}
    data['teacher']=teacher
    data['grade']=grade
    return data
def getRawClass(p):
    x={}
    data=BeautifulSoup(p.content, 'lxml')
    grades=data.findAll('a', { 'class' : 'bold' })
    tr=data.findAll('tr', {'id':re.compile('^ccid_\d+')})
    for i in range (0,6):
        td=tr[i].findAll('td')
        grade=td[len(td)-3]
        a=list(grade.find('a').getText())
        del a[0]
        a=''.join(a)
        teacher=tr[i].find('span',{ 'class' : 'screen_readers_only' }).parent['title'].strip('Details about ').replace(',','').split(' ')
        teacher.reverse()
        if(len(teacher)==3):
            del teacher[0]
        teacher= ' '.join(teacher)
        x['{}'.format(i+1)]=createSmallClass(teacher, a)
    return x
def createSmallAssignment(date, category, name, score, percent):
    data={}
    data['date']=date
    data['category']=category
    data['name']=name
    data['score']=score
    data['percent']=percent
    return data
def getRawAssignments(p,period):
    data=BeautifulSoup(p.content, 'lxml')
    grades=data.findAll('a', { 'class' : 'bold' })
    tr=data.findAll('tr', {'id':re.compile('^ccid_\d+')})
    td=tr[period-1].findAll('td')
    grade=td[len(td)-3]
    a=list(grade.find('a').getText())
    href='https://powerschool.sandi.net/guardian/'+grade.find('a')['href']

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
def getAllClass(p,period):
    data={}
    data['{}'.format(period)]=getRawAssignments(p,period)
    data['assignments']=data.pop('{}'.format(period))
    data['info']=getRawClass(p)['{}'.format(period)]
    return data
def getAllAssignments(p):
    data={}
    for i in range(1,7):
        data['{}'.format(i)]=getRawAssignments(p,i)
    return data
def getAllGrades(p):
    data={}
    for i in range(1,7):
        data['{}'.format(i)]=getAllClass(p,i)
    return data
def printJSON(data):
    print(json.dumps(data))
"""
