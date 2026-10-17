// Caps shared by the plugin source resolver and the archive validator.
// A plugin payload is downloaded into staging and then extracted; both the
// wire bytes and the decoded archive bytes are held to MAX_PAYLOAD_BYTES.

export const MAX_PAYLOAD_BYTES = 64 * 1024 * 1024;
export const MAX_METADATA_BYTES = 4 * 1024 * 1024;
export const MAX_PASTE_BYTES = 1 * 1024 * 1024;
