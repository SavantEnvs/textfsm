#!/usr/bin/env python3

import atheris
import sys
import fuzz_helpers

with atheris.instrument_imports(include=['textfsm']):
    import textfsm


def TestOneInput(data):
    fdp = fuzz_helpers.EnhancedFuzzedDataProvider(data)
    test_chosen = fdp.ConsumeIntInRange(0, 3)

    try:
        if test_chosen == 0:
            with fdp.ConsumeMemoryFile(all_data=True, as_bytes=False) as f:
                textfsm.TextFSM(f)
        elif test_chosen == 2:
            v = textfsm.TextFSMValue()
            v.Parse(fdp.ConsumeRemainingString())
        elif test_chosen == 3:
            textfsm.TextFSMRule(fdp.ConsumeRemainingString())
    except textfsm.Error:
        return -1


def main():
    atheris.Setup(sys.argv, TestOneInput)
    atheris.Fuzz()


if __name__ == "__main__":
    main()
