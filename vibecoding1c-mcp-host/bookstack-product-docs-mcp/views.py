"""Request-local server views; selectors only narrow the existing BookStack corpus."""
from contextvars import ContextVar
import json
import re
from urllib.parse import parse_qs

ACTIVE_VIEW = ContextVar('bookstack_product_view', default='')
SELECTORS = ('book_ids', 'chapter_ids', 'page_ids')


def load_views(text):
    views = json.loads(text or '{}')
    if not isinstance(views, dict):
        raise ValueError('BOOKSTACK_VIEWS_JSON must contain an object')
    for key, value in views.items():
        if not re.fullmatch(r'[a-z0-9][a-z0-9._-]*', key) or not isinstance(value, dict):
            raise ValueError('Invalid BookStack view identity')
        if set(value) - set(SELECTORS) or not value:
            raise ValueError('BookStack view requires explicit ID selectors')
        for selector, ids in value.items():
            if not isinstance(ids, list) or not ids or len(ids) > 500 or any(
                    isinstance(item, bool) or not isinstance(item, int) or item <= 0 for item in ids):
                raise ValueError('View selectors require 1..500 positive integer IDs')
    return views


def effective_filters(filters, views):
    result = dict(filters or {})
    if set(result) - {'type', 'book', 'tag', 'live', 'book_id', 'chapter_id', 'page_id', *SELECTORS}:
        raise ValueError('Unknown BookStack selector; scope cannot be widened')
    for singular in ('book_id', 'chapter_id', 'page_id'):
        if singular in result:
            value = result[singular]
            if isinstance(value, bool) or not isinstance(value, int) or value <= 0:
                raise ValueError(singular + ' must be a positive integer ID')
    for selector in SELECTORS:
        if selector in result:
            values = result[selector]
            if not isinstance(values, list) or len(values) > 500 or any(
                    isinstance(value, bool) or not isinstance(value, int) or value <= 0 for value in values):
                raise ValueError(selector + ' must be a bounded list of positive integer IDs')
    view_id = ACTIVE_VIEW.get()
    if view_id:
        if view_id not in views:
            raise ValueError('Unknown BookStack view')
        for selector, ids in views[view_id].items():
            result[selector] = sorted(set(result.get(selector, ids)) & set(ids))
    return result


class ViewRouter:
    """Preserve /mcp and bind /mcp?view=id or /views/id/mcp without redirects."""
    def __init__(self, app, views):
        self.app, self.views = app, views

    async def __call__(self, scope, receive, send):
        if scope['type'] != 'http':
            return await self.app(scope, receive, send)
        query = parse_qs(scope.get('query_string', b'').decode('ascii'), keep_blank_values=True)
        selected = query.get('view', [])
        path = scope.get('path', '')
        matched = re.fullmatch(r'/views/([^/]+)/mcp', path)
        if matched:
            if selected and selected != [matched[1]]:
                selected = ['', 'conflict']
            else:
                selected = [matched[1]]
            scope = dict(scope, path='/mcp', raw_path=b'/mcp')
        if selected and (len(selected) != 1 or selected[0] not in self.views):
            await send({'type': 'http.response.start', 'status': 404, 'headers': []})
            return await send({'type': 'http.response.body', 'body': b'Unknown BookStack view'})
        token = ACTIVE_VIEW.set(selected[0] if selected else '')
        try:
            return await self.app(scope, receive, send)
        finally:
            ACTIVE_VIEW.reset(token)
