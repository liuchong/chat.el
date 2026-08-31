#include "sample.h"

#include <assert.h>
#include <string.h>

static void test_divide(void) {
    unsigned result = 0;
    assert(divide_positive(5, 2, &result) == 0);
    assert(result == 3);
    assert(divide_positive(1, 0, &result) == -1);
}

static void test_label(void) {
    char output[64];
    assert(label("alpha", output, sizeof output) == 0);
    assert(strcmp(output, "entry:alpha") == 0);
}

static void test_normalize(void) {
    char output[64];
    assert(normalize_name("  Alpha   BETA ", output, sizeof output) == 0);
    assert(strcmp(output, "alpha beta") == 0);
}

static void test_active(void) {
    assert(active((struct status){.state = "active"}));
    assert(!active((struct status){.state = "paused"}));
}

int main(int argc, char **argv) {
    assert(argc == 2);
    if (strcmp(argv[1], "divide") == 0) test_divide();
    else if (strcmp(argv[1], "label") == 0) test_label();
    else if (strcmp(argv[1], "normalize") == 0) test_normalize();
    else if (strcmp(argv[1], "active") == 0) test_active();
    else return 2;
    return 0;
}
