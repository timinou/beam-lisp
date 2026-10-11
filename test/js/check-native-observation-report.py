#!/usr/bin/env python3
from pathlib import Path
from playwright.sync_api import sync_playwright
proof=Path(__file__).resolve().parents[2]/'docs/proof/runtime-observation/milestone-1'
with sync_playwright() as p:
 browser=p.chromium.launch(headless=True,executable_path='/home/user/.cache/ms-playwright/chromium-1243/chrome-linux64/chrome',args=['--no-sandbox'])
 try:
  page=browser.new_page(viewport={'width':1280,'height':1000});errors=[];page.on('pageerror',lambda e:errors.append(str(e)))
  page.goto((proof/'report.html').as_uri());assert page.locator('tbody tr').count()==8
  page.get_by_role('button',name='128-row sample',exact=True).click();assert page.locator('tbody tr').count()==128
  page.get_by_role('button',name='8-row sample',exact=True).click();page.screenshot(path=str(proof/'report.png'),full_page=True)
  assert not errors,errors
  print('interactive report: 8/128 row controls, no page errors, screenshot recorded')
 finally:browser.close()
