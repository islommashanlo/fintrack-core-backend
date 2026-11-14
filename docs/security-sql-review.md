# Reviewed SQL composition warnings

Reviewed on 2026-11-13 with Brakeman 8.1.0. These 25 specific SQL warnings are
false positives after tracing identifiers, values and all callers. Each has a
fingerprint-specific exception with its own rationale; no check, confidence level,
file or directory is excluded. SQL injection scanning remains enabled. The Rails
lifecycle warning was resolved by upgrading Rails, not by an exception.

An exception is not evidence that every future edit to its helper is safe. Re-review
both the sink and helper chain when changing those methods. Brakeman fingerprints
may survive edits to a helper, so reviewers must also inspect the source paths
listed here. CI requires nonempty notes and rejects obsolete exceptions.

## Source-by-source rationale

### app/services/alert_delivery_policy.rb:18

Fingerprint: `09074ec8c22a66f76e6a1dc333edbb4e650515cf31a0b371d3de18a4666c49bb`.

WatchlistFilingMembership.pending_sql chooses identifiers with DESTINATIONS.fetch using the literal email channel; WatchlistNewsMembership delegates to NewsAlertValidity with that same literal and server Time.current. Values in generated relations are bound/quoted; no request SQL enters the predicate.

### app/services/news_alert_validity.rb:47

Fingerprint: `0fe27c73810e86df11ba39aa5de4a43d7b11acd067460f06f0d301a5e630292b`.

watchlist_sources chooses column/table only through DESTINATIONS.fetch(channel); snapshot_sources and representative are ActiveRecord relations with bound as_of, ceilings and channel. representative.reselect.to_sql is already quoted SQL, not caller text.

### app/services/api/v1/cursor_page.rb:66

Fingerprint: `10d02b121aa4c136f5d2d6259f70c2024259195bb13ec3ce54d0d95795e47496`.

call_sql receives SQL only from internal query builders. Every caller supplies a fixed SORTS map or ScreenerDefinition.sorts from fixed FIELDS. initialize rejects unknown sorts; limits are bounded Integers; after-cursor values are sanitized and signed contexts bind bounds/filters.

### app/services/api/v1/company_history_query.rb:19

Fingerprint: `18e712bad8a78ae30c2c4e2355f8776a628453be580ec6a34d0921f3eb74be75`.

CompanyHistorySql.timeline uses bound ticker in mappings, fixed security filter keys with sanitize_sql, ActiveRecord report relations, and numeric server-generated/signed page bounds. from wraps this generated query, not a request SQL fragment.

### app/services/api/v1/fund_directory_query.rb:46

Fingerprint: `24ed5c411d9d31f45b15078e4db1f8340d06ebcbe2f15fc97a3d90dbc53d463a`.

RANGES.each_key supplies fixed column identifiers; validate_ranges! requires an anchored decimal/count pattern and checks ranges. Maximum values are passed through a ? bind, never interpolated into SQL.

### app/services/institutional_alert_validity.rb:11

Fingerprint: `3faabe94f4f657f63c332eb7b5018b242b972022f439be5e0ddeb5e2e4c4f1d3`.

as_of is connection.quote(d); report_sets_sql composes InstitutionalReportScope ActiveRecord relations with bound time/ID/report filters. The snapshot alias and all selected identifiers are fixed by internal callers.

### app/services/news_alert_matcher.rb:11

Fingerprint: `46a96b9b8fa709102b27c08577acb94139bef59a0aff595d49d5dbe0b944d121`.

News::Visibility.follow_match sanitizes as_of and Integer-converts optional ceilings; channel and scope are validated enums and bound separately. Join aliases are fixed; scope chooses only one of two literal joins.

### app/services/in_app_notification_policy.rb:11

Fingerprint: `483758b2421f391ce70b6fe68ea5295a16a788a2dcc3dcdc6716a1aa9da801f0`.

Pending watchlist SQL comes from fixed DESTINATIONS lookups and NewsAlertValidity generated relations. The in_app channel is literal and as_of values are bound/quoted, not request SQL. Entitlement subqueries and quota SQL are internally generated.

### app/services/alert_digest_planner.rb:17

Fingerprint: `4ad9b694e58ad8ba86171050e97aa3e77ebfa980628fb5d4a01a3ac0481c466f`.

Watchlist membership predicates use the literal email destination and quoted ActiveRecord news relations. Rule ownership/frequency/time conditions use relation hashes or binds; no user preference or notification string is inserted as SQL syntax.

### app/services/news_alert_validity.rb:40

Fingerprint: `4fff8dd3640650bf0185b892681f5f9d9978683b57b375b30dd302e675442542`.

watchlist representative aliases come from DESTINATIONS.fetch(channel); snapshot IDs are column comparisons and optional ceilings use ? binds. Unknown destinations raise KeyError before SQL generation.

### app/services/alert_evaluator.rb:51

Fingerprint: `521738bd8b13a85f00c37e39c94b7c35c11f2a29c4cd11d7d8fc05d265a1f949`.

base_sql is a literal SELECT. FilingFollowMatch.sql quotes filing ticker, CIK and ID via sanitize_sql with named/positional binds, including externally reported ticker text. Only known filing form branches can contribute a predicate.

### app/services/news_alert_validity.rb:34

Fingerprint: `61c10b4622d76bbf3a4af6c757e2d970be322875a522e54d0a56e334bfbd9581`.

apply composes valid.reselect.to_sql and watchlist_sources(email), both internally generated ActiveRecord queries. as_of is bound by snapshot_sources/Visibility; field/alias names come from fixed constants.

### app/services/api/v1/cursor_page.rb:110

Fingerprint: `6679b6aae5964cd0dd01b33d1131a1a5f29685f7b547642a972896a05f478ee2`.

after_cursor interpolates only a fixed map-selected column, model table_name and a literal comparison operator. Signed last_value/last_id are passed as named binds, not SQL syntax. Unknown sorts and mismatched cursor contexts are rejected.

### app/services/in_app_notification_matcher.rb:83

Fingerprint: `77dffff4ac523206bb74c0322ea6380cf833c4f8f7abc993facfd24ab85225f1`.

capture is private. Its source_sql comes only from filing_matches/TransactionAlertMatcher or snapshot/news VALUES builders that connection.quote every value. Event/conflict columns are fixed map entries; IDs/timestamps/event_type are connection.quote(d). No controller supplies source_sql.

### app/services/api/v1/cursor_page.rb:107

Fingerprint: `7eb69ba8f8b6cc618c169bf0ad680b0aee7358632cac661901b96e2651a23226`.

Null continuation branch uses a fixed sort-map column, model table_name and literal < or >. last_id is a ? bind; signed context and version are checked before restoring the snapshot.

### app/services/archive_inventory.rb:33

Fingerprint: `84e54b95b744b1adbee5b298c459967ae6f4f5a4b64dc516312f41f7f10d7213`.

filings is an ActiveRecord relation with fixed form constants/joins and a hash id filter. documents_sql is a literal UNION. Hostile filing_ids remain ActiveRecord-cast values and cannot change the CTE SQL syntax.

### app/services/alert_source_validity.rb:25

Fingerprint: `8fad6f639c367e9037c2a3e35830236d3fdd33d2ba39947586636efbf94b1318`.

ClusterAlertValidity.sql receives literal snapshot/filing column names from this caller, quotes as_of and composes Form4ReadScope relation SQL with bound visibility ceilings. No external column expression reaches this call.

### app/services/news_alert_validity.rb:22

Fingerprint: `a18587ac476660f16ac668316c3bd6550b15e84912aeb961b9d1e43c0584cf8b`.

notification_sources joins News::Visibility.follow_match: server time is sanitized and optional filing ceiling Integer-converted. Snapshot/item/mention filters use binds; final UNION combines two internally generated SQL relations.

### app/services/api/v1/insider_transactions_query.rb:165

Fingerprint: `afd0ca373f909bc0e8f7a0dbb7abe30828243b45b5ccbf31ef8fc2214416b1db`.

after_cursor chooses the column from fixed SORT_COLUMNS and operator from sort direction. Signed last_value and last_id enter named value/id binds; neither can become SQL syntax.

### app/services/api/v1/fund_directory_query.rb:45

Fingerprint: `bbaf0f12ec799aa26242a555358fdb34ebcf2dbe18d6a413c43d53aea1a98e98`.

Minimum range predicate uses RANGES fixed column keys and a ? value bind after anchored numeric format/range checks. Client text cannot supply a column or operator.

### app/services/in_app_notification_source.rb:27

Fingerprint: `c73ea706cf6ae8de6dbf734c6cc290f313f3d00d76c18db490cccf30b7b5bb5c`.

news is generated by NewsAlertValidity.notification_sources; forms/as_of are connection.quote(d), optional ceiling is Integer-converted, and filing_events_sql uses private fixed aliases and generated report/filing relations. No raw request SQL is accepted.

### app/services/archive_inventory.rb:38

Fingerprint: `dd083e83cd4439ae9470a5f8e28cbb1d3a0097ceef66b2fb768b75688e05bf79`.

coverage composes the same ActiveRecord-quoted filings relation and fixed documents_sql UNION as documents; aggregate fields, aliases and form literals are static. Supplied filing_ids are a hash predicate, not a SQL fragment.

### app/services/alert_source_validity.rb:16

Fingerprint: `e4184eec35955360c27d5605bbf0398dd22ba4e3d90ef336b78b0aa1aa6c65a0`.

Submission types are fixed SEC_INGEST_TYPES and each is connection.quote(d); as_of is connection.quote(d). Remaining syntax/identifiers are literal SQL; IDs are column-to-column comparisons.

### app/services/api/v1/insider_transactions_query.rb:162

Fingerprint: `e9fa7ba4ee08442609846fbb3d5aee7a08ab99ac1f4e1599d30de79c15b8ac44`.

Null-value pagination branch interpolates only fixed SORT_COLUMNS and a literal comparison operator; last_id is a ? bind from a context-verified signed cursor.

### app/services/api/v1/fund_position_history_query.rb:15

Fingerprint: `f8f0a7c3e9bd55e47262308b63a5a10dc2c26d8ab76effe3e98b8907ef6eecdb`.

timeline_sql uses sanitize_sql named binds for CUSIP/put_call/share_type, relation-generated visible/effective reports with hash fund ID, fixed portfolio SQL and numeric signed page bounds. from wraps this generated query, not request text.

## Verification and limits

`spec/services/sql_boundaries_spec.rb` executes SQL using hostile ticker/search/
screener values and signed continuation data, verifies archive ID selection stays
bounded and checks rejection of malicious sort/destination/ceiling inputs. Existing
API and alert suites exercise the generated queries, ownership and visibility
semantics across funds, company history, transactions, clusters and news. These
tests are regression evidence at shared boundaries, not an exhaustive proof of
all SQL helpers. No application SQL was relabeled with Arel.sql to hide warnings.

A full scan without the ignore file must retain these reviewed findings; the
normal scan should show zero unreviewed warnings and 25 reviewed exceptions.
Keep raw scanner output visible when reviewing new fingerprints and never add an
exception solely because an integration test passed.
