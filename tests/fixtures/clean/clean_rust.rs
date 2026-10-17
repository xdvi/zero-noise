pub struct Item {
    pub id: u64,
    pub name: String,
    pub score: f64,
    pub active: bool,
}

pub struct User {
    pub is_active: bool,
    pub is_super_admin: bool,
    pub items: Vec<Item>,
}

pub struct Config {
    pub allow_access: bool,
    pub maintenance: bool,
}

fn can_access(user: &User, config: &Config) -> bool {
    if user.is_super_admin && !config.maintenance {
        return true;
    }
    user.is_active && config.allow_access
}

fn to_scored_item(item: &Item) -> (u64, f64) {
    (item.id, item.score * 1.5)
}

pub fn handle_session(user: &User, config: &Config) -> bool {
    if !can_access(user, config) {
        return false;
    }

    let _scores: Vec<_> = user.items.iter().map(to_scored_item).collect();
    true
}
