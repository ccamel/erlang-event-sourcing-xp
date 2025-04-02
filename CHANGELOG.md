# erlang-event-sourcing-xp changelog

## 1.0.0 (2025-04-02)


### Features

* **core:** add core_mgr_aggregate implementation ([d901a2f](https://github.com/ccamel/erlang-event-sourcing-xp/commit/d901a2fdf91995f00ba2cf9f89979b723f1fff27))
* **core:** add dispatch/1 to aggregate to entirely hide gen_server ([f3a39cc](https://github.com/ccamel/erlang-event-sourcing-xp/commit/f3a39ccd6bbec7417ffb1f8ca32ebaefe514fb55))
* **core:** add ETS event store ([8f08219](https://github.com/ccamel/erlang-event-sourcing-xp/commit/8f08219bfe17cc085740bd67296ad2748161648f))
* **core:** add gen_server aggregate behaviour for event-sourced domain logic ([59593d3](https://github.com/ccamel/erlang-event-sourcing-xp/commit/59593d37a6fad65e3aaff6a66be25deca0f64b41))
* **core:** add limit option to event retrieval function ([cd27ea7](https://github.com/ccamel/erlang-event-sourcing-xp/commit/cd27ea7b741f3f42af3cf7b92fd8fb3bf38fc44d))
* **core:** handle conflicts and enfore atomicity in Mnesia persistence ([cfd16de](https://github.com/ccamel/erlang-event-sourcing-xp/commit/cfd16de7089031ba1705aa762a5d67d4f648bac1))
* **core:** improve mnesia storage management ([11985ab](https://github.com/ccamel/erlang-event-sourcing-xp/commit/11985ab67a0f339cb3e2a08a581a5584de07e263))
* **core:** introduce configurable sequence and timestamp options ([0598490](https://github.com/ccamel/erlang-event-sourcing-xp/commit/05984908be363e09b36b1c29adab90289f8d2fd6))
* **core:** introduce routing behaviour module ([090bec2](https://github.com/ccamel/erlang-event-sourcing-xp/commit/090bec2fd923e6abd39728fb42ccd6b9426fd3b3))
* **core:** log persisted events ([00ffe97](https://github.com/ccamel/erlang-event-sourcing-xp/commit/00ffe970feac627916edc099266004ddf02b8009))
* **core:** switch to persist_events for event stream batch persistence ([6373e32](https://github.com/ccamel/erlang-event-sourcing-xp/commit/6373e32468996ddc03b436ce008cf7b098baa25c))
* **core:** use cursor based limit queries for mnesia ([af36aa8](https://github.com/ccamel/erlang-event-sourcing-xp/commit/af36aa80ed065aaf79a55f51841de2266d53c060))
* **lib:** implement persist_event/3 and retrieve_and_fold_events/4 ([bc42558](https://github.com/ccamel/erlang-event-sourcing-xp/commit/bc42558529603da409c68d974e58e60bbea04aeb))
* **lib:** scaffold event_sourcing_core lib ([47edf82](https://github.com/ccamel/erlang-event-sourcing-xp/commit/47edf8262e0afaa18a0beaa8e06a6e3e1b956361))
* **store:** add helper function to easily retrieve events ([15c0c73](https://github.com/ccamel/erlang-event-sourcing-xp/commit/15c0c735e9fd682fa3bec8977ea910101c40014e))


### Bug Fixes

* **core:** perform batch insert of events in ETS backend ([6314d7c](https://github.com/ccamel/erlang-event-sourcing-xp/commit/6314d7cd01fdc7d07b36548a61137d4fed1abaaa))
