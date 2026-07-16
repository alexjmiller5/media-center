from core.config import Settings


def test_source_dbs_parses_comma_separated_env(monkeypatch):
    monkeypatch.setenv("NOTION_API_KEY", "k")
    monkeypatch.setenv("SOURCE_DBS", "db-1, db-2")
    assert Settings().source_dbs == ("db-1", "db-2")
