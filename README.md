# `psc` for PowerSchool
> A minimal command-line tool for reading grades from [PowerSchool](https://www.powerschool.com/).

Disclaimer: `psc` is not created by, affiliated with, or supported by PowerSchool.

## Installation
From the `psc` directory, run:
```sh
make install
```
for a full installation.

Alternatively, if you're working on `psc` in a development environment, you may wish to symlink the executable for ease of testing:
```sh
make link
```
To uninstall:
```sh
make uninstall
```
Any of these commands may require root privileges depending on your environment.

## Use
To view all grades:
```sh
psc
```
To view grade and task list for a specific class and marking period (not fully implemented yet):
```sh
psc -p 3 -m Q1
```

## License
[MIT](LICENSE)

## Author
[Erik Boesen](https://github.com/ErikBoesen)