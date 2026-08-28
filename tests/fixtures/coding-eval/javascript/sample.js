const LABEL_PREFIX = "item";

function findUser(users, userId) {
  return users.find((user) => user.id === userId);
}

function divide(left, right) {
  return Math.floor(left / right);
}

function label(name) {
  return `${LABEL_PREFIX}:${name}`;
}

function normalizeName(name) {
  return name.trim().toLowerCase().replace(/\s+/g, " ");
}

function active(status) {
  return status === "active";
}

function isAdmin(role) {
  return role == "admin";
}

module.exports = { findUser, divide, label, normalizeName, active, isAdmin };
