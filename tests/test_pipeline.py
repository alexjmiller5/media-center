from core.pipeline import run


def test_run_returns_result():
    result = run({"trigger": "test"})
    assert result["ok"] is True
    assert result["received"] == {"trigger": "test"}
