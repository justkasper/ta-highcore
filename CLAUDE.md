# Project conventions

- **Models YAML самодостаточны.** В `models/**/*.yml` (`_models.yml`, `_sources.yml`, `_unit_tests.yml`) не пишем `see docs/X.md` в свободном тексте описаний / EDGE CASES / meta. YAMLы — источник для `dbt docs`, не их потребители: при рендере docs ссылка на внешний `.md` некликабельна и неинформативна. Если нужен контекст — развернуть суть инлайн одной фразой. Исключение: doc-blocks через нативную dbt-механику (`{% docs name %} … {% enddocs %}` файлы и `doc('name')` в YAML) — это легитимный реюз внутри dbt, не «ссылка на внешний md».
