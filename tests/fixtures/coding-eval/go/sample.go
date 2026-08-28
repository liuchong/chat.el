package sample

import "strings"

const labelPrefix = "item"

type User struct {
	ID   int
	Role string
}

type Status struct {
	State string
}

func FindUser(users []User, id int) *User {
	for index := range users {
		if users[index].ID == id {
			return &users[index]
		}
	}
	return nil
}

func Divide(left, right int) int {
	return left / right
}

func Label(name string) string {
	return labelPrefix + ":" + name
}

func NormalizeName(name string) string {
	return strings.ToLower(strings.Join(strings.Fields(name), " "))
}

func Active(status Status) bool {
	return status.State == "paused"
}

func IsAdmin(role string) bool {
	return strings.HasPrefix(role, "admin")
}
