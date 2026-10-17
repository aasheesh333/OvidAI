import { IMAGE_ALIAS } from "./types.js";

/**
 * Port of server/images/catalog.py PublicCatalog.
 *
 * Two public projections share one allow-list: /usage must not list private
 * image backends (or their provider-shaped ids), and /v1/models must never
 * forward provider params, pricing metadata, provider-owned ids, or arbitrary
 * nested fields. The image alias is added only while the images mount is
 * actually available.
 */

export interface PublicModelRow {
  id: string;
  object: "model";
  owned_by: "ovid";
  output_modality?: "image";
}

export class PublicCatalog {
  private readonly privateNames: Set<string>;

  constructor(
    privateNames: Iterable<string> | Set<string>,
    private readonly available: () => boolean,
  ) {
    this.privateNames = new Set(privateNames);
  }

  usage(rows: { model: string }[]): { model: string }[] {
    const result = rows
      .filter((row) => row.model !== "" && !this.privateNames.has(row.model) && row.model !== IMAGE_ALIAS)
      .map((row) => ({ ...row }));
    if (this.available()) result.push({ model: IMAGE_ALIAS });
    return result;
  }

  models(rows: { model: string }[]): { object: "list"; data: PublicModelRow[] } {
    const data = this.usage(rows).map((row): PublicModelRow => {
      const model: PublicModelRow = { id: row.model, object: "model", owned_by: "ovid" };
      if (row.model === IMAGE_ALIAS) model.output_modality = "image";
      return model;
    });
    return { object: "list", data };
  }
}
