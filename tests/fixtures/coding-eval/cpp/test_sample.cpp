#include "sample.hpp"

#include <cassert>
#include <stdexcept>
#include <string>

static void testDivide() {
    assert(dividePositive(5, 2) == 3);
    try {
        (void)dividePositive(1, 0);
        assert(false);
    } catch (const std::invalid_argument&) {
    }
}

static void testLabel() {
    assert(label("alpha") == "entry:alpha");
}

static void testNormalize() {
    assert(normalizeName("  Alpha   BETA ") == "alpha beta");
}

static void testActive() {
    assert(active(Status{.state = "active"}));
    assert(!active(Status{.state = "paused"}));
}

int main(int argc, char** argv) {
    assert(argc == 2);
    const std::string test = argv[1];
    if (test == "divide") testDivide();
    else if (test == "label") testLabel();
    else if (test == "normalize") testNormalize();
    else if (test == "active") testActive();
    else return 2;
    return 0;
}
