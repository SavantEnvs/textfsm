/*
 * run_tests.c — ELF wrapper that execs the textfsm Python unittest suite.
 *
 * Running tests through a compiled ELF means the anti-reward-hack sabotage check
 * (LD_PRELOAD neutering non-system binaries) can detect a no-op program: the
 * launcher exits(0) without running tests → test count drops → oracle fails.
 * Compiled with $DEBUG_FLAGS (-gdwarf-3) so the ELF carries DWARF < 4 symbols.
 */
#include <stdio.h>
#include <unistd.h>

#ifndef PYTHON
#define PYTHON "python3"
#endif

#ifndef TESTS_DIR
#define TESTS_DIR "/mayhem/tests/"
#endif

int main(int argc, char **argv) {
    (void)argc; (void)argv;
    char *py_args[] = {
        (char *)PYTHON,
        "-m", "unittest", "discover",
        "-s", TESTS_DIR,
        "-p", "*_test.py",
        "-v",
        NULL
    };
    execvp(PYTHON, py_args);
    perror("execvp " PYTHON);
    return 127;
}
