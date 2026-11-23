import { useQuery } from "@tanstack/react-query";
import { unwrap } from "./rpc";
import { supabase } from "./supabase";

/**
 * Family documents (founder, 2026-11-23): folders of files, visible to the whole family. Files live in the
 * private Storage bucket "family-docs" at <group id>/<document id>/<file name>; the database row holds the
 * title, the label (shown as a sticker) and the comments.
 */
export const BUCKET = "family-docs";
export const MAX_BYTES = 25 * 1024 * 1024;

/** What the picker offers. iOS shows Photos and Files for this list. */
const TYPES: Record<string, string> = {
  pdf: "application/pdf",
  jpg: "image/jpeg", jpeg: "image/jpeg", png: "image/png", heic: "image/heic", heif: "image/heif", webp: "image/webp", gif: "image/gif",
  txt: "text/plain", csv: "text/csv", rtf: "application/rtf",
  doc: "application/msword", docx: "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
  xls: "application/vnd.ms-excel", xlsx: "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
  ppt: "application/vnd.ms-powerpoint", pptx: "application/vnd.openxmlformats-officedocument.presentationml.presentation",
};
export const ACCEPT = [...Object.keys(TYPES).map((e) => `.${e}`), "application/pdf", "image/*"].join(",");
const ALLOWED = new Set(Object.values(TYPES));

export function extOf(name: string): string {
  const m = /\.([a-z0-9]+)$/i.exec(name);
  return m ? m[1]!.toLowerCase() : "";
}

/** The type to store the file as, or null when fam.ly doesn't take it. Trusts the extension over an empty or odd browser type. */
export function mimeFor(file: File): string | null {
  if (ALLOWED.has(file.type)) return file.type;
  return TYPES[extOf(file.name)] ?? null;
}

/** A Storage-safe file name that keeps the extension. */
export function safeFileName(name: string): string {
  const ext = extOf(name);
  const base = name.replace(/\.[^.]*$/, "").normalize("NFKD").replace(/[^A-Za-z0-9_-]+/g, "-").replace(/^-+|-+$/g, "").slice(0, 100);
  return `${base || "file"}${ext ? `.${ext}` : ""}`;
}

/** "Passport scan.pdf" → "Passport scan" for the title field. */
export function titleFromName(name: string): string {
  return name.replace(/\.[^.]*$/, "").replace(/[_]+/g, " ").trim().slice(0, 80);
}

/** The short tag on the file tile: PDF, IMG, DOC, XLS, PPT, TXT. */
export function kindOf(mime: string): string {
  if (mime === "application/pdf") return "PDF";
  if (mime.startsWith("image/")) return "IMG";
  if (mime.includes("word")) return "DOC";
  if (mime.includes("excel") || mime.includes("spreadsheet") || mime === "text/csv") return "XLS";
  if (mime.includes("powerpoint") || mime.includes("presentation")) return "PPT";
  return "TXT";
}

export function formatSize(bytes: number): string {
  if (bytes < 1024) return `${bytes} B`;
  if (bytes < 1024 * 1024) return `${Math.round(bytes / 1024)} KB`;
  return `${(bytes / 1024 / 1024).toFixed(1).replace(/\.0$/, "")} MB`;
}

const STICKERS = ["sun", "mint", "lilac", "sky", "tomato"] as const;
/** The same label always gets the same sticker colour. */
export function stickerColour(label: string): (typeof STICKERS)[number] {
  let h = 0;
  for (const c of label.toLowerCase()) h = (h * 31 + c.charCodeAt(0)) >>> 0;
  return STICKERS[h % STICKERS.length]!;
}

export const SUGGESTED_LABELS = ["Passport", "ID", "Visa", "Insurance", "Medical", "Bank", "Receipt", "Contract"];

export const docKeys = {
  folders: (groupId: string) => ["doc-folders", groupId],
  folder: (folderId: string) => ["doc-folder", folderId],
  docs: (folderId: string) => ["docs", folderId],
  labels: (groupId: string) => ["doc-labels", groupId],
};

export function useDocFolders(groupId: string) {
  return useQuery({
    queryKey: docKeys.folders(groupId),
    enabled: !!groupId,
    queryFn: async () => {
      const rows = unwrap(
        await supabase.from("doc_folder").select("id, name, created_at, family_document(count)").eq("group_id", groupId).order("name"),
      );
      return rows.map((r) => ({
        id: r.id,
        name: r.name,
        count: (r.family_document as unknown as { count: number }[])[0]?.count ?? 0,
      }));
    },
  });
}

export function useDocFolder(folderId: string) {
  return useQuery({
    queryKey: docKeys.folder(folderId),
    enabled: !!folderId,
    queryFn: async () => unwrap(await supabase.from("doc_folder").select("*").eq("id", folderId).maybeSingle()),
  });
}

export function useFolderDocs(folderId: string) {
  return useQuery({
    queryKey: docKeys.docs(folderId),
    enabled: !!folderId,
    queryFn: async () =>
      unwrap(await supabase.from("family_document").select("*").eq("folder_id", folderId).order("created_at", { ascending: false })),
  });
}
export type FamilyDoc = NonNullable<ReturnType<typeof useFolderDocs>["data"]>[number];

/** Labels already used in the family, most used first, for one-tap reuse. */
export function useDocLabels(groupId: string) {
  return useQuery({
    queryKey: docKeys.labels(groupId),
    enabled: !!groupId,
    queryFn: async () => {
      const rows = unwrap(await supabase.from("family_document").select("label").eq("group_id", groupId).not("label", "is", null));
      const counts = new Map<string, number>();
      for (const r of rows) if (r.label) counts.set(r.label, (counts.get(r.label) ?? 0) + 1);
      return [...counts.entries()].sort((a, b) => b[1] - a[1]).map(([l]) => l);
    },
  });
}

/** A short-lived link to open the file (10 minutes; refreshed before it runs out). */
export function useFileLink(path: string | null) {
  return useQuery({
    queryKey: ["doc-link", path],
    enabled: !!path,
    staleTime: 8 * 60_000,
    queryFn: async () => {
      const { data, error } = await supabase.storage.from(BUCKET).createSignedUrl(path!, 600);
      if (error) throw error;
      return data.signedUrl;
    },
  });
}

/** Removes stored files after their rows are gone. Best effort: a failure leaves an unreachable file, not a broken row. */
export async function removeFiles(paths: string[]): Promise<void> {
  if (paths.length === 0) return;
  await supabase.storage.from(BUCKET).remove(paths).catch(() => undefined);
}
