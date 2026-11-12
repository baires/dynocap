import iniconfig


def add(a, b):
    if not isinstance(a, int) or not isinstance(b, int):
        raise TypeError("add expects integers")
    return a + b


def setting(text, section, key):
    return iniconfig.IniConfig("journey.ini", data=text)[section][key]
