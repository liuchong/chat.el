export interface User {
  id: number;
  name: string;
}

export interface Status {
  state: string;
}

const labelPrefix = "item";

export function findUser(users: readonly User[], userId: number): User | undefined {
  return users.find((user) => user.id === userId);
}

export function divide(left: number, right: number): number {
  return left / right;
}

export function label(name: string): string {
  return `${labelPrefix}:${name}`;
}

export function normalizeName(name: string): string {
  return name.trim().toLowerCase().split(/\s+/).join(" ");
}

export function active(status: Status): boolean {
  return (status as unknown) === "active";
}

export function isAdmin(role: string): boolean {
  return role.startsWith("admin");
}
