#!/usr/bin/env python3
"""Use the deployed converter page the way a person does, and capture each step for docs/converter.md.

    python3 tests/capture-converter-page.py https://<route host> tests/fixtures/ipsec-nas.json docs/images

It opens the address, logs in, converts the file once per theme, and saves the pictures and the downloaded
resource to the directory. Needs Playwright with Chromium. The login is OC_USER / OC_PASSWORD, by default
OpenShift Local's own `developer` user; the identity provider's button is the one named OC_PROVIDER.
"""
import os
import pathlib
import sys

from playwright.sync_api import sync_playwright

url, fixture, out = sys.argv[1], sys.argv[2], pathlib.Path(sys.argv[3])
out.mkdir(parents=True, exist_ok=True)


def shot(page, name, full=True):
    page.wait_for_timeout(400)
    page.screenshot(path=str(out / f"{name}.png"), full_page=full)
    print(f"captured {name}.png at {page.url.split('?')[0]}")


with sync_playwright() as p:
    browser = p.chromium.launch()
    ctx = browser.new_context(viewport={"width": 1180, "height": 900}, device_scale_factor=2,
                              ignore_https_errors=True, color_scheme="light", accept_downloads=True)
    page = ctx.new_page()
    failed = []
    page.on("requestfailed", lambda r: failed.append(f"{r.method} {r.url.split('?')[0]}: {r.failure}"))

    # 1. The address alone: the proxy sends an anonymous browser to the OpenShift login.
    page.goto(url, wait_until="networkidle")
    print("after opening the address, the browser is at:", page.url.split("?")[0])
    shot(page, "converter-login.light", full=False)

    provider = page.get_by_role("link", name=os.environ.get("OC_PROVIDER", "developer"))
    if provider.count():
        provider.first.click()
        page.wait_for_load_state("networkidle")
    page.fill("#inputUsername", os.environ.get("OC_USER", "developer"))
    page.fill("#inputPassword", os.environ.get("OC_PASSWORD", "developer"))
    page.click("button[type=submit]")
    page.wait_for_load_state("networkidle")

    # First login only: OpenShift asks the user to let the page read their identity.
    approve = page.locator("input[name=approve]")
    if approve.count():
        shot(page, "converter-authorize.light", full=False)
        approve.first.click()
        page.wait_for_load_state("networkidle")
    print("after the login, the browser is at:", page.url.split("?")[0])
    assert page.url.startswith(url), page.url

    for theme in ("light", "dark"):
        page.emulate_media(color_scheme=theme)
        page.goto(url, wait_until="networkidle")

        # 2. The input: the Grafana file, and where the dashboard goes.
        page.set_input_files("#file", fixture)
        if theme == "light":
            # A refusal first: the file alone, with no namespace.
            with page.expect_response(lambda r: r.url.endswith("/api/convert")) as info:
                page.click("#go")
            page.wait_for_selector("#error:not([hidden])")
            print("without a namespace: POST api/convert ->", info.value.status, "|", page.inner_text("#error"))
            shot(page, "converter-refused.light")
        page.fill("#namespace", "kcs-ipsec")
        page.fill("#name", "ipsec-nas")
        page.fill("#datasource", "ipsec-nas-thanos")
        page.check("#includeDatasource")
        shot(page, f"converter-form.{theme}")

        # 3. Convert, and the output.
        with page.expect_response(lambda r: r.url.endswith("/api/convert")) as info:
            page.click("#go")
        print(f"[{theme}] POST api/convert ->", info.value.status)
        page.wait_for_selector("#result:not([hidden])")
        print(f"[{theme}] summary:", page.inner_text("#summary"))
        print(f"[{theme}] adjustments:", page.locator("#adjustments .note").all_inner_texts())
        print(f"[{theme}] panel rows:", page.locator("#panels tr").count(), "| file:", page.inner_text("#filename"))
        page.evaluate("window.scrollTo(0, 0)")
        shot(page, f"converter-page.{theme}")

        if theme == "light":
            with page.expect_download() as dl:
                page.click("#download")
            target = out / dl.value.suggested_filename
            dl.value.save_as(str(target))
            print("downloaded", target.name, target.stat().st_size, "bytes")

    print("failed requests:", failed or "none")
    browser.close()
