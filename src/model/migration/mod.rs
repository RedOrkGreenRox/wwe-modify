use sea_orm_migration::prelude::*;

mod m20260503_000001_init_v1;
mod m20260504_000002_create_item_fts;
mod m20260505_000003_expand_item_fts_description;
mod m20260506_000004_add_item_stat_columns;
mod m20260507_000005_drop_playlist_tables;
mod m20260508_000006_swap_format_for_content_rating;

pub struct Migrator;

#[async_trait::async_trait]
impl MigratorTrait for Migrator {
    fn migrations() -> Vec<Box<dyn MigrationTrait>> {
        vec![
            Box::new(m20260503_000001_init_v1::Migration),
            Box::new(m20260504_000002_create_item_fts::Migration),
            Box::new(m20260505_000003_expand_item_fts_description::Migration),
            Box::new(m20260506_000004_add_item_stat_columns::Migration),
            Box::new(m20260507_000005_drop_playlist_tables::Migration),
            Box::new(m20260508_000006_swap_format_for_content_rating::Migration),
        ]
    }
}
