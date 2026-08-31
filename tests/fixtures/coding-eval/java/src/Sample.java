import java.util.List;
import java.util.Map;
import java.util.Optional;

public final class Sample {
    private static final String LABEL_PREFIX = "item";

    public record User(int id, String name) {}

    private Sample() {}

    public static Optional<User> findUser(List<User> users, int userId) {
        return users.stream().filter(user -> user.id() == userId).findFirst();
    }

    public static double divide(int left, int right) {
        return left / right;
    }

    public static String label(String name) {
        return LABEL_PREFIX + ":" + name;
    }

    public static String normalizeName(String name) {
        return String.join(" ", name.strip().toLowerCase().split("\\s+"));
    }

    public static boolean active(Map<String, String> status) {
        return status.equals("active");
    }

    public static boolean isAdmin(String role) {
        return role.startsWith("admin");
    }
}
