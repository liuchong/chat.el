#ifndef CHAT_EVAL_SAMPLE_HPP
#define CHAT_EVAL_SAMPLE_HPP

#include <optional>
#include <string>
#include <string_view>
#include <vector>

struct User {
    int id;
    std::string name;
};

struct Status {
    std::string state;
};

std::optional<User> findUser(const std::vector<User>& users, int userId);
unsigned dividePositive(unsigned left, unsigned right);
std::string label(std::string_view name);
std::string normalizeName(std::string_view name);
bool active(const Status& status);
bool isAdmin(std::string_view role);

#endif
