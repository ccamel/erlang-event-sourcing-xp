# erlang-event-sourcing-xp changelog

## [2.0.0](https://github.com/ccamel/erlang-event-sourcing-xp/compare/v1.1.0...v2.0.0) (2026-05-09)


### ⚠ BREAKING CHANGES

* **kernel:** change event store behavior to return result tuples
* **kernel:** rename domain to aggregate_type (everywhere)
* **kernel:** use aggregate_id instead of stream_id
* **kernel:** rename command key() to target() for clarity
* **kernel:** refine command, event and snapshot keys
* **kernel:** route all commands through a singleton aggregate manager
* **kernel:** remove manager behaviour (used for routing)
* **kernel:** remove lifecycle management from kernel layer
* **kernel:** turn the kernel into a plain OTP app

### Features

* **contract:** add contain/2 to the range ADT ([0f3eb9e](https://github.com/ccamel/erlang-event-sourcing-xp/commit/0f3eb9eb9f3f2103118ded83aff8cd10574a90f6))
* **contract:** add difference/2 to the range ADT ([cadf54a](https://github.com/ccamel/erlang-event-sourcing-xp/commit/cadf54afa427e6004dc28e6201964f55c22c9ce8))
* **contract:** add equal/2 to the range ADT ([4a85896](https://github.com/ccamel/erlang-event-sourcing-xp/commit/4a85896a230aea7581a53226410af5a3e9f34dae))
* **contract:** add intersection/2 to the range ADT ([31fb6c8](https://github.com/ccamel/erlang-event-sourcing-xp/commit/31fb6c8d8143c989500d748c9d685bbf09024a83))
* **contract:** add lt/2 to the range ADT ([439d82d](https://github.com/ccamel/erlang-event-sourcing-xp/commit/439d82d42b5d97008563fc941dbc3505df4475cd))
* **contract:** add overlap/2 to the range ADT ([5542f1f](https://github.com/ccamel/erlang-event-sourcing-xp/commit/5542f1f1bb8fb78026346dd6f051d2301193f9e9))
* **contract:** add projection checkpoint store behavior ([61c3bc7](https://github.com/ccamel/erlang-event-sourcing-xp/commit/61c3bc71ba4b2aa01673789b934601f884c522b5))
* **core:** refine store startup and validation ([5ed9e55](https://github.com/ccamel/erlang-event-sourcing-xp/commit/5ed9e553e67cb86c91646b53513c6ca84be52555))
* **example:** extract interactive bank account example into standalone script ([5ea9e33](https://github.com/ccamel/erlang-event-sourcing-xp/commit/5ea9e333b006e8f97260293cba4ad69890ea5937))
* **kernel:** add projection event log folding ([7bb5ce7](https://github.com/ccamel/erlang-event-sourcing-xp/commit/7bb5ce77b9fa7da0443df893f8c007b0618f182e))
* **kernel:** add projection runtime ([9ee6ddd](https://github.com/ccamel/erlang-event-sourcing-xp/commit/9ee6ddd31d2edfe023a703512afedddaf1de82d5))
* **kernel:** handle aggregate process failures in command dispatch ([f9c8691](https://github.com/ccamel/erlang-event-sourcing-xp/commit/f9c8691480d47159881789a2cc12f394c9541883))
* **kernel:** introduce registry mapping aggregate_type to aggregate_module ([0e2acc9](https://github.com/ccamel/erlang-event-sourcing-xp/commit/0e2acc980f173bb19549d71f9f7d5f089b217c36))
* **kernel:** make snapshot interval configurable ([d4b0f57](https://github.com/ccamel/erlang-event-sourcing-xp/commit/d4b0f57028c9482d01a5756ca1966a93492de498))
* **projection:** add managed projection runners ([1ccc6ae](https://github.com/ccamel/erlang-event-sourcing-xp/commit/1ccc6ae5a0624e7cf0faea7e445d20e8622539d9))
* **store_ets:** add global event positions ([b397992](https://github.com/ccamel/erlang-event-sourcing-xp/commit/b397992be87205d8e3555c6441ad460db337665d))
* **store_file:** add File store backend ([e16058b](https://github.com/ccamel/erlang-event-sourcing-xp/commit/e16058b69f7c2766ccd5a4447f4a5ffbf772b52e))
* **store_file:** add global event index ([19f5d73](https://github.com/ccamel/erlang-event-sourcing-xp/commit/19f5d73063373a59395975cc8fac82ee385afc16))
* **store_mnesia:** add global event positions ([0c09f08](https://github.com/ccamel/erlang-event-sourcing-xp/commit/0c09f080286e5945f70df07f24b191feb18ec4e8))
* **xp:** improve xp (demo) application ([32f777d](https://github.com/ccamel/erlang-event-sourcing-xp/commit/32f777d54449ab08c3cee868a7c3352596ea36bc))
* **xp:** wire projection runtime into demo app ([8c829cc](https://github.com/ccamel/erlang-event-sourcing-xp/commit/8c829cc962e3f9b13bfbce93aaf269bbc2f16c7f))


### Bug Fixes

* **contract:** correct behavior of advance/2 to return empty range when beyond upper bound ([4f7f60a](https://github.com/ccamel/erlang-event-sourcing-xp/commit/4f7f60ab2daa05a812fe0182094bb479614c0708))
* **contract:** correct error tuple for invalid range creation ([dff2608](https://github.com/ccamel/erlang-event-sourcing-xp/commit/dff260845da1298e1b294771c7d813d0397c5dc1))
* **file:** handle file:write_file error return type ([1c6b31e](https://github.com/ccamel/erlang-event-sourcing-xp/commit/1c6b31e9009233619b27a698e3dcd93cfd84f4fc))
* **kernel:** add (missing) event_type/1 callback to aggregate behavior ([97ec156](https://github.com/ccamel/erlang-event-sourcing-xp/commit/97ec156891c10299635c953139f694450d8b2948))
* **kernel:** add warning log for missing registry entry in init/1 ([c67b810](https://github.com/ccamel/erlang-event-sourcing-xp/commit/c67b810cdea4d78071b0eac7c25d13523437e6a5))
* **kernel:** align manager dispatch specs with actual return types ([95774e9](https://github.com/ccamel/erlang-event-sourcing-xp/commit/95774e9cf44c78d87d5c82093ae9ed3ffcb8b2fb))
* **kernel:** make checkpoint ets startup race-safe ([1c5e5db](https://github.com/ccamel/erlang-event-sourcing-xp/commit/1c5e5dbcad6e6687b4818e2ef85996f0ff7d6e7e))
* **kernel:** preserve event order in aggregate batches ([59046e4](https://github.com/ccamel/erlang-event-sourcing-xp/commit/59046e437240da1f53df3681acb12237d9c06076))
* **xp:** enforce positive withdraw amounts ([813f7da](https://github.com/ccamel/erlang-event-sourcing-xp/commit/813f7da84908a50e818bf185d4bfbf97871f7570))


### Documentation

* **kernel:** document projection runner failure mode ([7e768e4](https://github.com/ccamel/erlang-event-sourcing-xp/commit/7e768e49672dfc3e3c5b68a69760b3b50d4d40d7))
* **kernel:** tighten aggregate process documentation ([ff3cea9](https://github.com/ccamel/erlang-event-sourcing-xp/commit/ff3cea91f66786b7f62809bba67b5d2170bf96d4))
* **README:** add codecov badge ([c1aa4e3](https://github.com/ccamel/erlang-event-sourcing-xp/commit/c1aa4e327d8f6fce6d29623711d0c5e34c5c4ab2))
* **README:** add pull-based projection runtime and checkpointing details ([2dde721](https://github.com/ccamel/erlang-event-sourcing-xp/commit/2dde721ece56fd484e348bd9acee59ce736fc752))
* **README:** clarify command payload and aggregate type resolution ([19af86b](https://github.com/ccamel/erlang-event-sourcing-xp/commit/19af86b5792b4ce6067a1000f9ae48bee73b158b))
* **README:** describe file store backend (+ cosmetics) ([dd9174a](https://github.com/ccamel/erlang-event-sourcing-xp/commit/dd9174acd2d617924e1c9dff5aa3333d1a6b07af))
* **README:** describe lint workflow (dialyzer, fmt) ([9663a18](https://github.com/ccamel/erlang-event-sourcing-xp/commit/9663a189851092c79393015837326cf8066f41fc))
* **README:** document global event folding ([fa2f543](https://github.com/ccamel/erlang-event-sourcing-xp/commit/fa2f54371e1d5e8384db5622d3461a2db6ee9e62))
* **README:** document kernel refactor and supervision tree ([fdd21b4](https://github.com/ccamel/erlang-event-sourcing-xp/commit/fdd21b4515616aaf28c629510694dee059170409))
* **README:** document managed projections ([8cfdf16](https://github.com/ccamel/erlang-event-sourcing-xp/commit/8cfdf169befe4ceb6b7bcd6fbdfe93fa1c401fad))
* **README:** document projection app runtime ([6a4de80](https://github.com/ccamel/erlang-event-sourcing-xp/commit/6a4de80d85feabea0849a239f5755c3e70bb4984))
* **README:** include capabilities for each store ([29bfe3c](https://github.com/ccamel/erlang-event-sourcing-xp/commit/29bfe3ca4192b21f963310a0a119bed42a0994cc))
* **README:** refresh feature overview ([1eee3a9](https://github.com/ccamel/erlang-event-sourcing-xp/commit/1eee3a9f13fa75a635290c4b281ed7dc4e4c660a))
* **README:** specify event store backend roadmap ([e91c279](https://github.com/ccamel/erlang-event-sourcing-xp/commit/e91c279bba4344c2962a461f055123df8f17ecbd))


### Styles

* **contract:** polish style ([14990a8](https://github.com/ccamel/erlang-event-sourcing-xp/commit/14990a88d4c01a7905028448e27fbbbc97d6a1c5))
* fix line length lint ([8ee4e12](https://github.com/ccamel/erlang-event-sourcing-xp/commit/8ee4e123fbc9afdc8deec120fb9968f27c33a58e))
* **kernel:** make linter happy again ([7f509bb](https://github.com/ccamel/erlang-event-sourcing-xp/commit/7f509bb96b7dc7a93cebda0ee719b7f854776183))
* **kernel:** simplify metadata and tags handling ([0214388](https://github.com/ccamel/erlang-event-sourcing-xp/commit/02143885ccc5d566f2440e9fda049793b7eef5ac))


### Refactors

* apply es_ prefix to all modules (simplify naming) ([8ceee1e](https://github.com/ccamel/erlang-event-sourcing-xp/commit/8ceee1ed9e694c2bbd70eed4a391172b62657cc3))
* **contract:** change fold callback to use interval as first-class parameter ([6a020f2](https://github.com/ccamel/erlang-event-sourcing-xp/commit/6a020f274da01609250cea2651a85b4bda4248b3))
* **contract:** rename interval ADT into range ([c6c3056](https://github.com/ccamel/erlang-event-sourcing-xp/commit/c6c30561867a752a5023217f9be03e18e0c48b54))
* **core:** split store behaviours ([a6022c2](https://github.com/ccamel/erlang-event-sourcing-xp/commit/a6022c2043b40f4787a3d8b81fa06123488b1558))
* extract event sourcing contract into dedicated app ([33241ee](https://github.com/ccamel/erlang-event-sourcing-xp/commit/33241eea41191e684fc1481c7ab13266896ec5c8))
* **kernel:** change event store behavior to return result tuples ([8186b17](https://github.com/ccamel/erlang-event-sourcing-xp/commit/8186b170878ca5ae3480abfb16e9a8e3f228ddf1))
* **kernel:** configure store via OTP application environment ([6fb6c45](https://github.com/ccamel/erlang-event-sourcing-xp/commit/6fb6c45811d557a9908f34f6c225d44686a8a7ef))
* **kernel:** extract rehydration logic from aggregate init ([60c7c70](https://github.com/ccamel/erlang-event-sourcing-xp/commit/60c7c70d60ea779091f64040d24ed6abbf0dd8b4))
* **kernel:** migrate es_kernel_aggregate_sup to modern dynamic supervisor ([f2001cf](https://github.com/ccamel/erlang-event-sourcing-xp/commit/f2001cf13deae1f518ecc6c707dd743e8a788da6))
* **kernel:** refine command, event and snapshot keys ([8ad27c2](https://github.com/ccamel/erlang-event-sourcing-xp/commit/8ad27c25444c7d7970363ce9e9f324703149d879))
* **kernel:** remove lifecycle management from kernel layer ([07ddecb](https://github.com/ccamel/erlang-event-sourcing-xp/commit/07ddecbf8c1e13b63d0b225871295f68e9c34a5c))
* **kernel:** remove manager behaviour (used for routing) ([acb0e75](https://github.com/ccamel/erlang-event-sourcing-xp/commit/acb0e75950264e7192b42c4faa8edb141c142da5))
* **kernel:** remove wrapper functions from es_kernel_store ([d835daf](https://github.com/ccamel/erlang-event-sourcing-xp/commit/d835daf926f1b985c8f37fabe4e508a97ef8529c))
* **kernel:** rename command key() to target() for clarity ([58d60e9](https://github.com/ccamel/erlang-event-sourcing-xp/commit/58d60e9be95bdad5a90c6036ae13545f775aeba9))
* **kernel:** rename dispatch to execute in es_kernel_aggregate ([cb49631](https://github.com/ccamel/erlang-event-sourcing-xp/commit/cb49631f5eabf4a55a4d32f35cd338d1055fa154))
* **kernel:** rename domain to aggregate_type (everywhere) ([4188fc1](https://github.com/ccamel/erlang-event-sourcing-xp/commit/4188fc1a346046cf4532c872402624a990d0607e))
* **kernel:** restructure stream_id as {domain, aggregate_id} tuple ([b475ab7](https://github.com/ccamel/erlang-event-sourcing-xp/commit/b475ab7c92596ba6fc80fd4c8742bf6e44ed4013))
* **kernel:** route all commands through a singleton aggregate manager ([ed6c697](https://github.com/ccamel/erlang-event-sourcing-xp/commit/ed6c6972e88e18226ae58ce7c1965fea02f00adc))
* **kernel:** turn the kernel into a plain OTP app ([b7af467](https://github.com/ccamel/erlang-event-sourcing-xp/commit/b7af467b32193ebc6b391ede4fee314f51f44268))
* **kernel:** use aggregate_id instead of stream_id ([eade7e5](https://github.com/ccamel/erlang-event-sourcing-xp/commit/eade7e5c0afde8e4dd70467b3888d3e4d33f0004))
* merge es_contract into es_kernel application ([f23018a](https://github.com/ccamel/erlang-event-sourcing-xp/commit/f23018a7859e94c00e0fee051cac2bf306c889b3))
* move contract types to dedicated modules ([6c9bd74](https://github.com/ccamel/erlang-event-sourcing-xp/commit/6c9bd74907577b10e1b4c64ed5d06cf17985c561))
* **projection:** move projection runtime to dedicated app ([93a5f07](https://github.com/ccamel/erlang-event-sourcing-xp/commit/93a5f0752eb3fcea59fbe073b23170a5eb0d3113))
* **range:** normalize/relax range creation logic ([8cac1d9](https://github.com/ccamel/erlang-event-sourcing-xp/commit/8cac1d95c664b8183c702950a354576ea8b816ae))
* remove configurable sequence_zero and sequence_next functions ([055087e](https://github.com/ccamel/erlang-event-sourcing-xp/commit/055087eddb2013e011e5f3e127e382f2886b7ea3))
* rename es_core to es_kernel ([d7fd4c1](https://github.com/ccamel/erlang-event-sourcing-xp/commit/d7fd4c1765ecf0755f182dc6b2a82f005a62b976))
* rename event store and snapshot store callbacks ([74a5dc4](https://github.com/ccamel/erlang-event-sourcing-xp/commit/74a5dc4d9a7550c278ce5a19094a981665ce8194))
* reorder fold/4 callback parameters ([39d927e](https://github.com/ccamel/erlang-event-sourcing-xp/commit/39d927e4344e96f76aea475fadbcbee101e8dc00))
* split store backends into dedicated apps ([fa9dd51](https://github.com/ccamel/erlang-event-sourcing-xp/commit/fa9dd51f4a2ef831e79f4cbc342c861cc2867143))
* **store_ets:** make store_es a standalone OTP application ([73f716d](https://github.com/ccamel/erlang-event-sourcing-xp/commit/73f716d72569e7e41e8f4c3d86584cbb83dcdf84))
* **store_ets:** parametrize table name with configurable defaults ([d66b918](https://github.com/ccamel/erlang-event-sourcing-xp/commit/d66b918f5b479b91c13ac71fe8409e3cfd0b0221))
* **store_mnesia:** make store_es a standalone OTP application ([d37902e](https://github.com/ccamel/erlang-event-sourcing-xp/commit/d37902e549f46447776744d2a113da724f39c913))
* **store_mnesia:** parametrize table name with configurable defaults ([de2300e](https://github.com/ccamel/erlang-event-sourcing-xp/commit/de2300e133e2217bcd7b7db09b90b33410b428d1))
* **store:** clarify meaning of store context ([844e054](https://github.com/ccamel/erlang-event-sourcing-xp/commit/844e0543a32cd566e7deba766f845fc04cf14c34))
* **store:** split event and snapshot stores ([bcb6199](https://github.com/ccamel/erlang-event-sourcing-xp/commit/bcb619914c22f780f77961cd7481171b015b78f0))


### Performance Improvements

* **kernel:** optimize retrieve_events to build event lists in O(n) ([889be9e](https://github.com/ccamel/erlang-event-sourcing-xp/commit/889be9e974818d76f63e410a291f92aa996ad24d))


### Tests

* **contract:** add comprehensive unit tests for event_sourcing_interval module ([012d846](https://github.com/ccamel/erlang-event-sourcing-xp/commit/012d8465ebcf6197c6ee891b9597e28f955a86b3))
* **contract:** cover contain/2 for the range ADT ([f9839c1](https://github.com/ccamel/erlang-event-sourcing-xp/commit/f9839c17a299b8f8886e0c7dcc2281a0044ad439))
* **contract:** cover difference/2 for the range ADT ([90a7533](https://github.com/ccamel/erlang-event-sourcing-xp/commit/90a75337a7ad4fb0eb0661397e0ef8498a0722b9))
* **contract:** cover equal/2 for the range ADT ([b6072e1](https://github.com/ccamel/erlang-event-sourcing-xp/commit/b6072e1dc668ee412561add6759a7faefbd37b5a))
* **contract:** cover intersection/2 for the range ADT ([a7d047b](https://github.com/ccamel/erlang-event-sourcing-xp/commit/a7d047b7a4f7dcdb02675e042045d7764358bf59))
* **contract:** cover lt/2 for the range ADT ([b73e816](https://github.com/ccamel/erlang-event-sourcing-xp/commit/b73e8164babf39a61c9b19c3c65219296b9d85cf))
* **contract:** cover overlap/2 for the range ADT ([2fd9119](https://github.com/ccamel/erlang-event-sourcing-xp/commit/2fd91194ad4f978ccbefcb12178fa79bfde2cf1b))
* **contract:** make range tests black-box ([f994fa5](https://github.com/ccamel/erlang-event-sourcing-xp/commit/f994fa5c877e5e7ee8217562e5500950dc4165ea))
* **kernel:** add aggregate_survives_dead_worker test case ([cb450e0](https://github.com/ccamel/erlang-event-sourcing-xp/commit/cb450e0402a5b5e3a9f00afe85a3272038bc23af))
* **kernel:** cover file store backend ([0236ec9](https://github.com/ccamel/erlang-event-sourcing-xp/commit/0236ec9360822aafcde0dc4b0a3f5c21769fc657))
* **kernel:** cover global event folding ([1e65094](https://github.com/ccamel/erlang-event-sourcing-xp/commit/1e65094f6528f468a73547282dda7f921115d9bc))
* **kernel:** cover projection runtime ([5d779e3](https://github.com/ccamel/erlang-event-sourcing-xp/commit/5d779e30f78eccf897ce04d3c25afc8ab9c5967f))
* **projection:** cover projection management ([79830cd](https://github.com/ccamel/erlang-event-sourcing-xp/commit/79830cdd89d28b7032778ff9939293965edf4032))
* **projection:** ensure polling runner cleanup ([f5e6a33](https://github.com/ccamel/erlang-event-sourcing-xp/commit/f5e6a33d723c0a6de747d556211010d2dc126165))
* remove domain from aggregateId (not necessary) ([ced40f8](https://github.com/ccamel/erlang-event-sourcing-xp/commit/ced40f8822e7b4568a7bd15a5d7ca6c8d2dffd59))
* **xp:** put bank_account_aggregate under testing ([21f5df0](https://github.com/ccamel/erlang-event-sourcing-xp/commit/21f5df005eacbb7bc391999f7b469bb03da54b79))


### Build System

* **agents:** bring erlang_otp_developer to life ([43d6fc1](https://github.com/ccamel/erlang-event-sourcing-xp/commit/43d6fc10103c3f9e6f08dc45e45c027911b9827f))
* **agents:** remove unnecessary tools field ([61731ec](https://github.com/ccamel/erlang-event-sourcing-xp/commit/61731ec3a808c7643c24b755618a9c162ad05bc7))
* **deps:** bump actions/cache from 4 to 5 ([2db2fc8](https://github.com/ccamel/erlang-event-sourcing-xp/commit/2db2fc816a1cba666ef3b177213f864c793d01d8))
* **deps:** bump actions/checkout from 5 to 6 ([beed6fc](https://github.com/ccamel/erlang-event-sourcing-xp/commit/beed6fc9c1a4d634de13fe411b53c72e2a416f12))
* **deps:** bump codecov/codecov-action from 5 to 6 ([4a3c7a4](https://github.com/ccamel/erlang-event-sourcing-xp/commit/4a3c7a40f9212d0cfaf697734c21a702f90a577d))
* **deps:** bump crazy-max/ghaction-import-gpg from 6 to 7 ([8522c7c](https://github.com/ccamel/erlang-event-sourcing-xp/commit/8522c7c3fba4582f184436d4c90ac7051f9a89fb))
* **project:** configure covertool coverdata properly ([809ce64](https://github.com/ccamel/erlang-event-sourcing-xp/commit/809ce64499b6ea660e7de757fb697b7c7b916f65))
* **rebar:** add projection app to umbrella ([25fce84](https://github.com/ccamel/erlang-event-sourcing-xp/commit/25fce844dd785a857cf702d058c5bd21306e5e9f))
* **release:** add escript to generate release BOM ([dcaf2f4](https://github.com/ccamel/erlang-event-sourcing-xp/commit/dcaf2f469d155badc9c48be423477841074f7f29))
* **release:** categorize non-feature commits in changelog ([ec7d421](https://github.com/ccamel/erlang-event-sourcing-xp/commit/ec7d421d7f4aa0cc09dc3476ce72846338cfafbf))


### Continuous Integration

* **codecov:** ignore demo app coverage ([4a597e2](https://github.com/ccamel/erlang-event-sourcing-xp/commit/4a597e2044d9c1c637cbc1409645206190020c91))
* **workflow:** addcoverage reporting job and upload to Codecov ([22c0631](https://github.com/ccamel/erlang-event-sourcing-xp/commit/22c0631427d7181575a68ead7a3c241cc002d828))
* **workflow:** ensure injected demo snippet is up to date ([884609c](https://github.com/ccamel/erlang-event-sourcing-xp/commit/884609ca856e7487a059624308fc67da15792caf))
* **workflow:** fix example script path ([deea666](https://github.com/ccamel/erlang-event-sourcing-xp/commit/deea666c78308a6fb034be670db7300c9ac90efe))


### Chores

* **project:** add data directory to git ignore list ([9cdf6a3](https://github.com/ccamel/erlang-event-sourcing-xp/commit/9cdf6a3d7f0f8937b462cc88604a7b88e87fb4e5))

## [1.1.0](https://github.com/ccamel/erlang-event-sourcing-xp/compare/v1.0.0...v1.1.0) (2025-10-25)


### Features

* **core:** add ETS-based snapshot storage ([c0813df](https://github.com/ccamel/erlang-event-sourcing-xp/commit/c0813df48998cd95cb4b300f45d26232a4b44dd0))
* **core:** add Mnesia-based snapshot storage ([3917490](https://github.com/ccamel/erlang-event-sourcing-xp/commit/3917490ba1da4ef3986638c89f4c4a134c6e2e87))
* **core:** introduce snapshot mechanism ([cefcfb6](https://github.com/ccamel/erlang-event-sourcing-xp/commit/cefcfb6969d2fa9afd488f1a55ed09a03ccfee98))

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
