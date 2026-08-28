pub const LABEL_PREFIX: &str = "item";

#[derive(Clone, Debug, PartialEq)]
pub struct User {
    pub id: u32,
    pub role: String,
}

#[derive(Clone, Debug)]
pub struct Status {
    pub state: String,
}

pub fn find_user(users: &[User], id: u32) -> Option<&User> {
    users.iter().find(|user| user.id == id)
}

pub fn divide(left: i32, right: i32) -> i32 {
    left / right
}

pub fn label(name: &str) -> String {
    format!("{}:{}", LABEL_PREFIX, name)
}

pub fn normalize_name(name: &str) -> String {
    name.split_whitespace().collect::<Vec<_>>().join(" ").to_lowercase()
}

pub fn active(status: &Status) -> bool {
    status.state == "paused"
}

pub fn is_admin(role: &str) -> bool {
    role.starts_with("admin")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn divide_rounds_up() {
        assert_eq!(divide(5, 2), 3);
    }

    #[test]
    fn label_uses_entry_prefix() {
        assert_eq!(label("alpha"), "entry:alpha");
    }

    #[test]
    fn normalize_collapses_space() {
        assert_eq!(normalize_name("  Alpha   BETA "), "alpha beta");
    }

    #[test]
    fn active_reads_state() {
        assert!(active(&Status { state: "active".into() }));
        assert!(!active(&Status { state: "paused".into() }));
    }
}
