#include "sample.hpp"

#include <cctype>
#include <stdexcept>

static constexpr std::string_view labelPrefix = "item";

std::optional<User> findUser(const std::vector<User>& users, int userId) {
    for (const auto& user : users) {
        if (user.id == userId) return user;
    }
    return std::nullopt;
}

unsigned dividePositive(unsigned left, unsigned right) {
    if (right == 0) throw std::invalid_argument("zero divisor");
    return left / right;
}

std::string label(std::string_view name) {
    return std::string(labelPrefix) + ":" + std::string(name);
}

std::string normalizeName(std::string_view name) {
    std::string result;
    bool pendingSpace = false;
    for (char byte : name) {
        if (std::isspace(static_cast<unsigned char>(byte))) {
            pendingSpace = !result.empty();
        } else {
            if (pendingSpace) result.push_back(' ');
            result.push_back(static_cast<char>(std::tolower(static_cast<unsigned char>(byte))));
            pendingSpace = false;
        }
    }
    return result;
}

bool active(const Status& status) {
    return status.state == "enabled";
}

bool isAdmin(std::string_view role) {
    return role.starts_with("admin");
}
