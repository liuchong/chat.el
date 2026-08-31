import java.util.Map;

public final class SampleTest {
    private static void require(boolean condition, String message) {
        if (!condition) {
            throw new AssertionError(message);
        }
    }

    private static void divide() {
        require(Sample.divide(5, 2) == 2.5, "division must preserve fractions");
        try {
            Sample.divide(1, 0);
            throw new AssertionError("zero divisor must fail");
        } catch (IllegalArgumentException expected) {
            // Expected contract.
        }
    }

    private static void label() {
        require("entry:alpha".equals(Sample.label("alpha")), "label prefix");
    }

    private static void normalize() {
        require("alpha beta".equals(Sample.normalizeName("  Alpha   BETA ")),
                "name normalization");
    }

    private static void active() {
        require(Sample.active(Map.of("state", "active")), "active state");
        require(!Sample.active(Map.of("state", "paused")), "paused state");
    }

    public static void main(String[] args) {
        if (args.length != 1) {
            throw new IllegalArgumentException("one test name required");
        }
        switch (args[0]) {
            case "divide" -> divide();
            case "label" -> label();
            case "normalize" -> normalize();
            case "active" -> active();
            default -> throw new IllegalArgumentException("unknown test: " + args[0]);
        }
    }
}
