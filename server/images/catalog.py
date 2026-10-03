"""Public projections shared by /v1/models and the verifier's /usage list."""
from .service import ALIAS


class PublicCatalog:
    def __init__(self, backends, available):
        self.available = available
        self.private = {name for backend in backends for name in
                        (backend.model, 'openai/' + backend.model, backend.model.split('/', 1)[-1])}

    def usage(self, rows):
        result = [dict(row) for row in rows if row.get('model') not in self.private | {ALIAS}]
        if self.available():
            result.append({'model': ALIAS})
        return result

    def models(self, rows):
        # Construct a minimal public response; never forward provider params,
        # pricing metadata, provider-owned IDs, or arbitrary nested fields.
        public = [{'id': row['model'], 'object': 'model', 'owned_by': 'ovid'}
                  for row in self.usage(rows) if row.get('model')]
        for row in public:
            if row['id'] == ALIAS:
                row['output_modality'] = 'image'
        return {'object': 'list', 'data': public}
