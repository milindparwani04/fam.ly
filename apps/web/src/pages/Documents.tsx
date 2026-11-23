import { useRef, useState, type ChangeEvent, type FormEvent, type ReactNode } from "react";
import { createPortal } from "react-dom";
import { Link, useNavigate, useParams } from "react-router";
import { ExternalIcon, FileIcon, FolderIcon, PlusIcon, UploadIcon } from "../components/Icons";
import {
  ACCEPT, BUCKET, MAX_BYTES, SUGGESTED_LABELS, docKeys, formatSize, kindOf, mimeFor, removeFiles, safeFileName, stickerColour,
  titleFromName, useDocFolder, useDocFolders, useDocLabels, useFileLink, useFolderDocs, type FamilyDoc,
} from "../lib/docs";
import { useAction, useCurrentGroup, useMembers } from "../lib/queries";
import { messageOf, unwrap } from "../lib/rpc";
import { supabase } from "../lib/supabase";
import { Sheet, useUI } from "../lib/ui";

type Group = NonNullable<ReturnType<typeof useCurrentGroup>["group"]>;

/** Bottom sheet over the whole app (tab bar included), like the app-level sheets. */
function AppSheet(props: { label: string; onClose: () => void; children: ReactNode }) {
  const host = document.querySelector(".app") ?? document.body;
  return createPortal(<Sheet label={props.label} onClose={props.onClose}>{props.children}</Sheet>, host);
}

/** The label sticker: a tilted pastel tag on the file's corner. */
function DocSticker({ label, big = false }: { label: string; big?: boolean }) {
  return <span className={`doc-sticker ${stickerColour(label)}${big ? " big" : ""}`}>{label}</span>;
}

/* ------------------------------------------------------------------ Folders */

export function Documents() {
  const { group } = useCurrentGroup();
  return group ? <DocumentsBody group={group} /> : null;
}

/** Settings → Documents (founder, 2026-11-23): the family's folders. Everyone in the family sees all of them. */
function DocumentsBody({ group }: { group: Group }) {
  const folders = useDocFolders(group.id);
  const [creating, setCreating] = useState(false);
  return (
    <>
      <p className="set-sub">Keep important papers in folders. Everyone in {group.name} can see them.</p>
      {folders.error && <p className="error" role="alert">{messageOf(folders.error)}</p>}
      <div className="folder-grid">
        {(folders.data ?? []).map((f) => (
          <Link key={f.id} to={`/documents/${f.id}`} className={`folder-tile ${stickerColour(f.name)}`}>
            <FolderIcon className="folder-ico" />
            <span className="folder-name">{f.name}</span>
            <span className="folder-count">{f.count === 0 ? "Empty" : `${f.count} file${f.count === 1 ? "" : "s"}`}</span>
          </Link>
        ))}
        <button className="folder-tile new" onClick={() => setCreating(true)} disabled={folders.isPending}>
          <PlusIcon className="folder-ico" />
          <span className="folder-name">New Folder</span>
        </button>
      </div>
      {folders.data?.length === 0 && (
        <p className="muted docs-hint">Start with a folder for each person, like your own name, or one for the house or the car.</p>
      )}
      {creating && <FolderNameSheet group={group} onClose={() => setCreating(false)} />}
    </>
  );
}

/** New folder, or rename one (with delete). */
function FolderNameSheet(props: { group: Group; folder?: { id: string; name: string }; onClose: () => void }) {
  const navigate = useNavigate();
  const ui = useUI();
  const [name, setName] = useState(props.folder?.name ?? "");
  const [confirmDelete, setConfirmDelete] = useState(false);
  const docs = useFolderDocs(props.folder?.id ?? "");
  const keys = [docKeys.folders(props.group.id), ...(props.folder ? [docKeys.folder(props.folder.id)] : [])];
  const save = useAction(async () => {
    if (props.folder) {
      unwrap(await supabase.rpc("rpc_rename_doc_folder", { p_folder_id: props.folder.id, p_name: name }));
      return props.folder.id;
    }
    return unwrap(await supabase.rpc("rpc_create_doc_folder", { p_group_id: props.group.id, p_name: name }));
  }, keys);
  const remove = useAction(async () => {
    const paths = unwrap(await supabase.rpc("rpc_delete_doc_folder", { p_folder_id: props.folder!.id }));
    await removeFiles(paths);
  }, [docKeys.folders(props.group.id), docKeys.labels(props.group.id)]);

  function submit(e: FormEvent) {
    e.preventDefault();
    save.mutate(undefined, {
      onSuccess: (id) => {
        props.onClose();
        if (props.folder) ui.toast("Folder renamed");
        else navigate(`/documents/${id}`);
      },
    });
  }
  const n = docs.data?.length ?? 0;

  return (
    <AppSheet label={props.folder ? "Edit folder" : "New folder"} onClose={props.onClose}>
      <h2>{props.folder ? "Edit Folder" : "New Folder"}</h2>
      <form className="stack" onSubmit={submit}>
        <label>
          Folder Name
          <input autoFocus maxLength={60} value={name} onChange={(e) => setName(e.target.value)} placeholder="e.g. your name, or House &amp; Car" />
        </label>
        {save.error && <p className="error" role="alert">{messageOf(save.error)}</p>}
        <button type="submit" className="confirm-btn press" disabled={!name.trim() || save.isPending}>
          {save.isPending ? "Saving…" : props.folder ? "Save" : "Create Folder"}
        </button>
      </form>
      {props.folder && !confirmDelete && (
        <button className="sheet-link danger-link" onClick={() => setConfirmDelete(true)}>Delete this folder</button>
      )}
      {props.folder && confirmDelete && (
        <div className="delete-box">
          <span className="t">Delete {props.folder.name}?</span>
          <p>{n === 0 ? "The folder is empty." : `Its ${n} file${n === 1 ? "" : "s"} will be deleted too, for everyone.`} This can&apos;t be undone.</p>
          {remove.error && <p className="error">{messageOf(remove.error)}</p>}
          <div className="field-row">
            <button className="danger" disabled={remove.isPending}
                    onClick={() => remove.mutate(undefined, { onSuccess: () => { ui.toast("Folder deleted"); navigate("/documents", { replace: true }); } })}>
              Delete
            </button>
            <button className="secondary" onClick={() => setConfirmDelete(false)}>Cancel</button>
          </div>
        </div>
      )}
    </AppSheet>
  );
}

/* ------------------------------------------------------------------ One folder */

export function DocFolder() {
  const { group } = useCurrentGroup();
  const { folderId = "" } = useParams();
  return group ? <DocFolderBody group={group} folderId={folderId} /> : null;
}

function DocFolderBody({ group, folderId }: { group: Group; folderId: string }) {
  const folder = useDocFolder(folderId);
  const docs = useFolderDocs(folderId);
  const input = useRef<HTMLInputElement>(null);
  const [picked, setPicked] = useState<File | null>(null);
  const [pickError, setPickError] = useState<string | null>(null);
  const [openId, setOpenId] = useState<string | null>(null);
  const [editingFolder, setEditingFolder] = useState(false);

  if (folder.isPending) return <p className="muted">Loading…</p>;
  if (!folder.data) return <p className="error">This folder doesn&apos;t exist any more.</p>;

  function pick(e: ChangeEvent<HTMLInputElement>) {
    const file = e.target.files?.[0];
    e.target.value = "";
    if (!file) return;
    if (!mimeFor(file)) return setPickError("fam.ly takes PDFs, photos, Word, Excel, PowerPoint and text files.");
    if (file.size > MAX_BYTES) return setPickError(`That file is ${formatSize(file.size)}. Files can be up to 25 MB.`);
    setPickError(null);
    setPicked(file);
  }

  const list = docs.data ?? [];
  const open = list.find((d) => d.id === openId) ?? null;

  return (
    <>
      <div className="folder-head">
        <span className={`folder-badge ${stickerColour(folder.data.name)}`}><FolderIcon /></span>
        <h2>{folder.data.name}</h2>
        <button className="sheet-link" onClick={() => setEditingFolder(true)}>Edit</button>
      </div>

      <input ref={input} type="file" accept={ACCEPT} hidden onChange={pick} />
      <button className="confirm-btn press add-doc" onClick={() => input.current?.click()}>
        <UploadIcon /> Add Document
      </button>
      {pickError && <p className="error" role="alert">{pickError}</p>}

      {docs.error && <p className="error" role="alert">{messageOf(docs.error)}</p>}
      {!docs.isPending && list.length === 0 && (
        <div className="card empty">Nothing here yet. Add a PDF, a photo or a scan from your phone.</div>
      )}
      <ul className="doc-list">
        {list.map((d) => (
          <li key={d.id}>
            <button className="doc-card" onClick={() => setOpenId(d.id)}>
              <span className="doc-type">{kindOf(d.mime_type)}</span>
              <span className="doc-text">
                <span className="doc-title">{d.title}</span>
                <span className="doc-meta">{shortDate(d.created_at, group.time_zone)} · {formatSize(d.size_bytes)}{d.comment ? " · has notes" : ""}</span>
              </span>
              {d.label && <DocSticker label={d.label} />}
            </button>
          </li>
        ))}
      </ul>

      {picked && <AddDocSheet group={group} folderId={folderId} file={picked} onClose={() => setPicked(null)} />}
      {open && <DocSheet group={group} doc={open} onClose={() => setOpenId(null)} />}
      {editingFolder && <FolderNameSheet group={group} folder={folder.data} onClose={() => setEditingFolder(false)} />}
    </>
  );
}

function shortDate(iso: string, tz: string, long = false): string {
  return new Intl.DateTimeFormat("en-GB", { timeZone: tz, day: "numeric", month: "short", ...(long ? { year: "numeric" } : {}) }).format(new Date(iso));
}

/* ------------------------------------------------------------------ Add */

interface DocFields {
  title: string;
  label: string;
  comment: string;
}

/** Title, Document Label (with one-tap suggestions) and Comments. Shared by Add and Edit. */
function DocFieldsForm({ group, v, set }: { group: Group; v: DocFields; set: (v: DocFields) => void }) {
  const used = useDocLabels(group.id);
  const suggestions = [...new Set([...(used.data ?? []), ...SUGGESTED_LABELS])]
    .filter((l) => l.toLowerCase() !== v.label.trim().toLowerCase()).slice(0, 8);
  return (
    <>
      <label>
        Title
        <input maxLength={80} value={v.title} onChange={(e) => set({ ...v, title: e.target.value })} placeholder="e.g. UK Passport" />
      </label>
      <label>
        <span>Document Label <span className="muted">(optional, shown as a sticker)</span></span>
        <input maxLength={24} value={v.label} onChange={(e) => set({ ...v, label: e.target.value })} placeholder="e.g. Passport" />
      </label>
      <div className="label-picks" role="group" aria-label="Suggested labels">
        {suggestions.map((l) => (
          <button key={l} type="button" className={`doc-sticker pick ${stickerColour(l)}`} onClick={() => set({ ...v, label: l })}>{l}</button>
        ))}
      </div>
      <label>
        <span>Comments <span className="muted">(optional)</span></span>
        <textarea rows={3} maxLength={1000} value={v.comment} onChange={(e) => set({ ...v, comment: e.target.value })}
                  placeholder="e.g. Expires March 2031. Original is in the study drawer." />
      </label>
    </>
  );
}

function AddDocSheet(props: { group: Group; folderId: string; file: File; onClose: () => void }) {
  const ui = useUI();
  const [v, setV] = useState<DocFields>({ title: titleFromName(props.file.name), label: "", comment: "" });
  const add = useAction(async () => {
    const id = crypto.randomUUID();
    const path = `${props.group.id}/${id}/${safeFileName(props.file.name)}`;
    const up = await supabase.storage.from(BUCKET).upload(path, props.file, { contentType: mimeFor(props.file)!, upsert: false });
    if (up.error) throw new Error("The upload didn't go through. Check your connection and try again.");
    try {
      return unwrap(await supabase.rpc("rpc_add_document", {
        p_folder_id: props.folderId, p_document_id: id, p_storage_path: path, p_title: v.title, p_label: v.label, p_comment: v.comment,
      }));
    } catch (e) {
      await removeFiles([path]);
      throw e;
    }
  }, [docKeys.docs(props.folderId), docKeys.folders(props.group.id), docKeys.labels(props.group.id)]);

  function submit(e: FormEvent) {
    e.preventDefault();
    add.mutate(undefined, { onSuccess: () => { props.onClose(); ui.toast("Document added"); } });
  }

  return (
    <AppSheet label="Add document" onClose={add.isPending ? () => undefined : props.onClose}>
      <h2>Add Document</h2>
      <div className="picked-file">
        <span className="doc-type">{kindOf(mimeFor(props.file) ?? "")}</span>
        <span className="doc-text">
          <span className="doc-title">{props.file.name}</span>
          <span className="doc-meta">{formatSize(props.file.size)}</span>
        </span>
      </div>
      <form className="stack" onSubmit={submit}>
        <DocFieldsForm group={props.group} v={v} set={setV} />
        {add.error && <p className="error" role="alert">{messageOf(add.error)}</p>}
        <button type="submit" className="confirm-btn press" disabled={!v.title.trim() || add.isPending}>
          {add.isPending ? "Uploading…" : "Save Document"}
        </button>
      </form>
    </AppSheet>
  );
}

/* ------------------------------------------------------------------ View / edit / delete */

function DocSheet({ group, doc, onClose }: { group: Group; doc: FamilyDoc; onClose: () => void }) {
  const ui = useUI();
  const members = useMembers(group.id);
  const folders = useDocFolders(group.id);
  const link = useFileLink(doc.storage_path);
  const [mode, setMode] = useState<"view" | "edit" | "delete">("view");
  const [v, setV] = useState<DocFields>({ title: doc.title, label: doc.label ?? "", comment: doc.comment ?? "" });
  const [folderId, setFolderId] = useState(doc.folder_id);
  const keys = [docKeys.docs(doc.folder_id), docKeys.docs(folderId), docKeys.folders(group.id), docKeys.labels(group.id)];
  const save = useAction(async () => unwrap(await supabase.rpc("rpc_update_document", {
    p_document_id: doc.id, p_title: v.title, p_label: v.label, p_comment: v.comment, p_folder_id: folderId,
  })), keys);
  const remove = useAction(async () => {
    const path = unwrap(await supabase.rpc("rpc_delete_document", { p_document_id: doc.id }));
    await removeFiles([path]);
  }, keys);
  const by = members.data?.find((m) => m.user_id === doc.uploaded_by)?.display_name;

  if (mode === "edit") {
    return (
      <AppSheet label="Edit document" onClose={onClose}>
        <h2>Edit Document</h2>
        <form className="stack" onSubmit={(e) => {
          e.preventDefault();
          save.mutate(undefined, { onSuccess: () => { onClose(); ui.toast(folderId === doc.folder_id ? "Saved" : "Moved"); } });
        }}>
          <DocFieldsForm group={group} v={v} set={setV} />
          <label>
            Folder
            <select value={folderId} onChange={(e) => setFolderId(e.target.value)}>
              {(folders.data ?? []).map((f) => <option key={f.id} value={f.id}>{f.name}</option>)}
            </select>
          </label>
          {save.error && <p className="error" role="alert">{messageOf(save.error)}</p>}
          <button type="submit" className="confirm-btn press" disabled={!v.title.trim() || save.isPending}>
            {save.isPending ? "Saving…" : "Save"}
          </button>
          <button type="button" className="secondary" onClick={() => setMode("view")}>Cancel</button>
        </form>
      </AppSheet>
    );
  }

  return (
    <AppSheet label={doc.title} onClose={onClose}>
      <div className="doc-preview">
        <FileIcon className="doc-preview-ico" />
        <span className="doc-type">{kindOf(doc.mime_type)}</span>
        {doc.label && <DocSticker label={doc.label} big />}
      </div>
      <h2>{doc.title}</h2>
      <p className="doc-meta">
        {[by && `Added by ${by}`, shortDate(doc.created_at, group.time_zone, true), formatSize(doc.size_bytes)].filter(Boolean).join(" · ")}
      </p>
      {doc.comment && (
        <div className="doc-comment">
          <span className="eyebrow">Comments</span>
          <p className="pre">{doc.comment}</p>
        </div>
      )}
      {link.data ? (
        <a className="button block confirm-link" href={link.data} target="_blank" rel="noopener noreferrer">
          <ExternalIcon /> Open {kindOf(doc.mime_type) === "IMG" ? "Photo" : "File"}
        </a>
      ) : (
        <button className="confirm-btn" disabled>{link.error ? "Couldn't load the file" : "Getting file…"}</button>
      )}
      {mode === "view" ? (
        <div className="field-row">
          <button className="secondary" onClick={() => setMode("edit")}>Edit</button>
          <button className="secondary danger-text" onClick={() => setMode("delete")}>Delete</button>
        </div>
      ) : (
        <div className="delete-box">
          <span className="t">Delete {doc.title}?</span>
          <p>It&apos;s removed for everyone in {group.name}. This can&apos;t be undone.</p>
          {remove.error && <p className="error">{messageOf(remove.error)}</p>}
          <div className="field-row">
            <button className="danger" disabled={remove.isPending}
                    onClick={() => remove.mutate(undefined, { onSuccess: () => { onClose(); ui.toast("Document deleted"); } })}>
              Delete
            </button>
            <button className="secondary" onClick={() => setMode("view")}>Cancel</button>
          </div>
        </div>
      )}
    </AppSheet>
  );
}
