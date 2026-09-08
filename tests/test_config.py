from core.config import Settings


def test_settings_read_the_four_env_vars(monkeypatch):
    monkeypatch.setenv("LIFE_HUB_URL", "https://hub.example")
    monkeypatch.setenv("LIFE_HUB_TOKEN", "lt_x")
    monkeypatch.setenv("TMDB_API_KEY", "tmdb")
    monkeypatch.setenv("YOUTUBE_API_KEY", "yt")
    s = Settings()
    assert s.life_hub_url == "https://hub.example"
    assert s.life_hub_token == "lt_x"
    assert s.tmdb_api_key == "tmdb"
    assert s.youtube_api_key == "yt"
