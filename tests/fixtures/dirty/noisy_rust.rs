pub struct User {
    pub is_active: bool,
    pub is_super_admin: bool,
    pub is_suspended: bool,
    pub items: Vec<Item>,
}

pub struct Item {
    pub id: u64,
    pub name: String,
    pub score: f64,
    pub status: String,
    pub valid: bool,
}

pub struct Config {
    pub allow_access: bool,
    pub maintenance: bool,
}

pub fn handle_session(user: &User, config: &Config) -> bool {
    // Complex inline boolean conditional without semantic abstraction
    if user.is_active && config.allow_access || user.is_super_admin && !config.maintenance {
        println!("ACTIVE");
    }

    // Deep nesting level 3 (> 2) inside function
    if user.is_active {
        for item in &user.items {
            if item.valid {
                println!("{}", item.name);
            }
        }
    }

    // Long inline closure (> 80 chars)
    let _mapped: Vec<_> = user.items.iter().map(|it| (it.id, it.name.clone(), it.score * 1.5, it.status == "ACTIVE")).collect();

    // Unnecessary else block after early return
    if user.is_suspended {
        return false;
    } else {
        println!("Not suspended");
    }

    return false;
}
