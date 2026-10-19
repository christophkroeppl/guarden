import pathlib
import tempfile

from guarden import config as config_mod


def _write_config(text: str) -> pathlib.Path:
    tmp = pathlib.Path(tempfile.mkdtemp())
    path = tmp / "guarden.toml"
    path.write_text(text)
    return path


def _base(name: str = "staging") -> str:
    return (
        "[[environments]]\n"
        f'name = "{name}"\n'
        'kind = "slot"\n'
    )


def test_resolve_provider_identity_when_unmapped():
    path = _write_config(_base())
    cfg = config_mod.load(path)
    assert cfg.resolve_provider("staging", "postgres") == "postgres"


def test_resolve_provider_maps_per_track():
    path = _write_config(
        _base("staging")
        + _base("production").replace('name = "production"', 'name = "production"')
        + "[providers.staging]\n"
        'postgres = "postgres-staging"\n'
        + "[providers.production]\n"
        'postgres = "postgres-production"\n'
    )
    cfg = config_mod.load(path)
    assert cfg.resolve_provider("staging", "postgres") == "postgres-staging"
    assert cfg.resolve_provider("production", "postgres") == "postgres-production"


def test_resolve_provider_full_name_passes_through():
    path = _write_config(
        _base("production")
        + "[providers.production]\n"
        'postgres = "postgres-production"\n'
    )
    cfg = config_mod.load(path)
    assert cfg.resolve_provider("production", "postgres-production") == "postgres-production"


def test_providers_not_a_table_refused():
    path = _write_config('providers = "nope"\n')
    try:
        config_mod.load(path)
        raise AssertionError("expected refusal")
    except Exception as exc:
        assert "providers" in str(exc)


def test_providers_value_not_a_string_refused():
    path = _write_config(
        _base("staging")
        + "[providers.staging]\n"
        "postgres = 5\n"
    )
    try:
        config_mod.load(path)
        raise AssertionError("expected refusal")
    except Exception as exc:
        assert "postgres" in str(exc)


if __name__ == "__main__":
    test_resolve_provider_identity_when_unmapped()
    test_resolve_provider_maps_per_track()
    test_resolve_provider_full_name_passes_through()
    test_providers_not_a_table_refused()
    test_providers_value_not_a_string_refused()
    print("ALL TESTS PASSED")
