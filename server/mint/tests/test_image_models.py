"""/usage image-model surface: generate/edit/size capabilities, free models
(explicit zero price never consumes allowance) and no key/base-URL leakage."""
import hashlib
import json

from conftest import standard_models, user_with_keys

AUTH = {"X-Firebase-AppCheck": "x"}


def get_usage(c, uid):
    r = c.post("/usage", headers={"Authorization": f"Bearer {uid}", **AUTH})
    assert r.status_code == 200, r.text
    return r.json()


def by_id(body):
    return {m["id"]: m for m in body["image_models"]}


def add_image(fake, name, under, *, per_image=None, out_per_token=None,
              mode="image_generation", endpoints=None, sizes=None,
              api_base=None, info_extra=None, params_extra=None):
    """Publish one image deployment in the fake LiteLLM /model/info."""
    info = {"id": f"dep-{len(fake.models)}", "mode": mode}
    if per_image is not None:
        info["output_cost_per_image"] = per_image
    if out_per_token is not None:
        info["output_cost_per_token"] = out_per_token
    if endpoints is not None:
        info["supported_endpoints"] = list(endpoints)
    if sizes is not None:
        info["supported_sizes"] = list(sizes)
    info.update(info_extra or {})
    params = {"model": under}
    if api_base:
        params["api_base"] = api_base
    params.update(params_extra or {})
    fake.models.append({"model_name": name,
                        "litellm_params": params,
                        "model_info": info})
    return info


def walk(value):
    if isinstance(value, dict):
        for key, item in value.items():
            yield key, item
            yield from walk(item)
    elif isinstance(value, list):
        for item in value:
            yield from walk(item)


def test_image_models_expose_generate_edit_and_sizes(client):
    c, mint, fake, _ = client
    fake.add_model("glm-5.3-flash", "prov/glm-5.3-flash", 2e-7, 8e-7, mode="chat")
    add_image(fake, "plain-image", "prov/plain", per_image=0.04,
              endpoints=["/v1/images/generations"], sizes=["1024x1024"])
    add_image(fake, "editor-image", "prov/editor", per_image=0.05,
              endpoints=["/v1/images/generations", "/v1/images/edits"],
              sizes=["1024x1024", "1536x1024", "1024x1536"])
    user_with_keys(mint, fake, "u")

    body = get_usage(c, "u")
    imgs = by_id(body)
    assert set(imgs) == {"plain-image", "editor-image"}
    assert imgs["plain-image"]["capabilities"] == {
        "generate": True, "edit": False, "sizes": ["1024x1024"]}
    assert imgs["plain-image"]["kind"] == "image"
    assert imgs["editor-image"]["capabilities"] == {
        "generate": True, "edit": True,
        "sizes": ["1024x1024", "1536x1024", "1024x1536"]}
    assert imgs["editor-image"]["priced"] is True
    assert imgs["editor-image"]["free"] is False
    assert imgs["editor-image"]["remaining_images"] == int(0.15 / 0.05 + 1e-9)
    # The legacy model-row contract is unchanged (capabilities live in their
    # own list); chat models are not image models.
    assert set(by_id(body)) == {m["id"] for m in body["models"] if m["kind"] == "image"}
    assert all("capabilities" not in m for m in body["models"])
    assert "glm-5.3-flash" not in imgs


def test_image_model_without_declared_facts_is_generate_only(client):
    c, mint, fake, _ = client
    add_image(fake, "quiet-image", "prov/quiet", per_image=0.02)
    user_with_keys(mint, fake, "u")
    card = by_id(get_usage(c, "u"))["quiet-image"]["capabilities"]
    assert card == {"generate": True, "edit": False, "sizes": ["1024x1024"]}


def test_edit_only_image_model_does_not_claim_generate(client):
    c, mint, fake, _ = client
    add_image(fake, "retouch", "prov/retouch", per_image=0.03, mode="image_edit",
              endpoints=["/v1/images/edits"])
    user_with_keys(mint, fake, "u")
    card = by_id(get_usage(c, "u"))["retouch"]["capabilities"]
    assert card["generate"] is False and card["edit"] is True


def test_zero_price_image_model_stays_free_when_allowance_is_gone(client):
    c, mint, fake, _ = client
    mint.rds.set(mint.BASE_BUDGET_KEY, "1")
    add_image(fake, "paid-image", "prov/paid", per_image=0.04)
    add_image(fake, "free-per-image", "prov/free-per", per_image=0.0)
    add_image(fake, "free-token-image", "prov/free-token", out_per_token=0.0)
    toks = user_with_keys(mint, fake, "u", web=False)
    fake.add_log(toks["android"], "prov/paid", group="paid-image", spend=1.0, ago_min=0)

    body = get_usage(c, "u")
    assert body["remaining_fraction"] == 0
    imgs = by_id(body)
    assert imgs["paid-image"]["priced"] is True
    assert imgs["paid-image"]["remaining_images"] == 0
    for name in ("free-per-image", "free-token-image"):
        row = imgs[name]
        assert row["free"] is True, name
        assert row["priced"] is False, name
        assert row["remaining_images"] is None, name
        # A free model still advertises what it can do.
        assert row["capabilities"]["generate"] is True
        assert row["capabilities"]["sizes"] == ["1024x1024"]


def test_image_alias_merges_private_backend_capabilities(client, monkeypatch):
    """server/images hides private image backends and publishes one alias; the
    alias must still describe the union of what those backends can do."""
    c, mint, fake, _ = client
    add_image(fake, "img-backend-a", "prov/a", per_image=0.02,
              endpoints=["/v1/images/generations"], sizes=["1024x1024"])
    add_image(fake, "img-backend-b", "prov/b", per_image=0.0,
              endpoints=["/v1/images/generations", "/v1/images/edits"],
              sizes=["1024x1024", "1536x1024"])
    inner = mint._available_models
    monkeypatch.setattr(mint, "_available_models", lambda: [
        r for r in inner() if not r["model"].startswith("img-backend")] + [{"model": "studio-alias"}])
    mint.rds.set(mint.BASE_BUDGET_KEY, "1")
    user_with_keys(mint, fake, "u")

    row = by_id(get_usage(c, "u"))["studio-alias"]
    assert row["capabilities"] == {
        "generate": True, "edit": True, "sizes": ["1024x1024", "1536x1024"]}
    # The alias is priced at the dearest backend, so it is not "free" just
    # because one of its backends costs nothing.
    assert row["priced"] is True and row["free"] is False


def test_image_surface_never_leaks_keys_or_base_urls(client):
    c, mint, fake, _ = client
    secret_base = "https://private-images.internal.example/v1"
    secret_key = "sk-image-upstream-abc123456"
    add_image(fake, "leaky-image", "prov/leaky", per_image=0.04,
              api_base=secret_base,
              info_extra={"api_key": secret_key,
                          "api_base": secret_base,
                          "extra_headers": {"Authorization": f"Bearer {secret_key}"}})
    toks = user_with_keys(mint, fake, "u")

    response = c.post("/usage", headers={"Authorization": "Bearer u", **AUTH})
    assert response.status_code == 200, response.text
    body = response.json()
    raw = response.text
    assert body["image_models"], "image model should still be advertised"
    assert by_id(body)["leaky-image"]["capabilities"]["generate"] is True

    forbidden = [secret_base, "private-images.internal.example", secret_key,
                 "sk-u-a", "sk-u-w", toks["android"], toks["web"],
                 hashlib.sha256(toks["android"].encode()).hexdigest(),
                 hashlib.sha256(toks["web"].encode()).hexdigest(),
                 "http://litellm", "Bearer "]
    for value in forbidden:
        assert value not in raw, value
    fields = {str(k).lower() for k, _ in walk(body)}
    assert not fields & {"api_base", "base_url", "api_key", "key", "token"}
    # Capabilities are an allow-list: no provider endpoints or upstream model
    # names escape with them.
    assert set(by_id(body)["leaky-image"]["capabilities"]) == {"generate", "edit", "sizes"}


def test_chat_only_catalog_has_no_image_models(client):
    c, mint, fake, _ = client
    standard_models(fake)
    fake.models[:] = [m for m in fake.models if m["model_name"] != "ovid-image"]
    user_with_keys(mint, fake, "u")
    assert get_usage(c, "u")["image_models"] == []
