# Project conventions

- **YAML — источник доков, SQL — код. Кросс-ссылок между ними не пишем:**
  - В YAML (`_models.yml`, `_sources.yml`, `_unit_tests.yml`, `_tests.yml`, `_macros.yml`) свободный текст описаний / EDGE CASES / meta не ссылается на `docs/*.md`. YAML рендерится в `dbt docs`; внешняя `.md`-ссылка там некликабельна и неинформативна. Нужен контекст — инлайн одной фразой.
  - В SQL-файлах (`models/**/*.sql`, `tests/*.sql`, `macros/*.sql`) заголовочный стуб вида `-- See tests/_tests.yml for full docs` — шум: файлы парные по имени, doc-блок найдут и так.
  - Исключение: doc-blocks через нативную dbt-механику (`{% docs name %} … {% enddocs %}` файлы и `doc('name')` в YAML) — это легитимный реюз внутри dbt.
