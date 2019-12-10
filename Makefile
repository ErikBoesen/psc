exec = psc
dest = /usr/local/bin

install:
	install -m 0755 $(exec) $(dest)

link:
	ln -s $(realpath $(exec)) $(dest)

uninstall:
	rm $(dest)/$(exec)

purge: uninstall
	rm ~/.psc.yml
	rm ~/.psc_credentials.yml
