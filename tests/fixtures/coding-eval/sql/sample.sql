CREATE TABLE users (
    id INTEGER PRIMARY KEY,
    name TEXT NOT NULL
);

-- find_user resolves a row by numeric identifier. No row means no result.
CREATE VIEW find_user AS
SELECT id, name
FROM users;

CREATE TABLE ratios (
    left_value INTEGER NOT NULL,
    right_value INTEGER NOT NULL
);

CREATE VIEW division_results AS
SELECT left_value,
       right_value,
       CASE
         WHEN right_value = 0 THEN NULL
         ELSE left_value / right_value
       END AS result
FROM ratios;

CREATE TABLE items (
    name TEXT NOT NULL
);

CREATE VIEW item_labels AS
SELECT 'item:' || name AS label
FROM items;

CREATE TABLE people (
    raw_name TEXT NOT NULL
);

CREATE VIEW normalized_names AS
SELECT lower(trim(replace(raw_name, '  ', ' '))) AS name
FROM people;

CREATE TABLE statuses (
    state TEXT NOT NULL
);

CREATE VIEW active_statuses AS
SELECT state, state = 'enabled' AS active
FROM statuses;

CREATE TABLE roles (
    role TEXT NOT NULL
);

CREATE VIEW administrator_roles AS
SELECT role, role LIKE 'admin%' AS administrator
FROM roles;
