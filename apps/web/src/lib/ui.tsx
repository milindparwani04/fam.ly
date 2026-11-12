import { createContext, useCallback, useContext, useEffect, useMemo, useRef, useState, type ReactNode } from "react";

/** Which bottom sheet is open (Stickers handoff: Book A Car, Car Schedule; plus I'm Leaving and Add Car). */
export type SheetState =
  | { kind: "book"; vehicleId?: string | undefined }
  | { kind: "schedule"; vehicleId: string }
  | { kind: "leave"; outingId?: string | undefined }
  | { kind: "addCar" }
  | { kind: "rate"; menuId: string }
  | { kind: "person"; userId: string }
  | null;

interface UI {
  sheet: SheetState;
  open: (s: SheetState) => void;
  close: () => void;
  toast: (message: string) => void;
  toastMessage: string | null;
}

const Ctx = createContext<UI | null>(null);

export function useUI(): UI {
  const ui = useContext(Ctx);
  if (!ui) throw new Error("useUI outside UIProvider");
  return ui;
}

/** Holds the open sheet and the toast. Toasts confirm every quick action and hide after 2.2 s. */
export function UIProvider({ children }: { children: ReactNode }) {
  const [sheet, setSheet] = useState<SheetState>(null);
  const [toastMessage, setToast] = useState<string | null>(null);
  const timer = useRef<number | undefined>(undefined);
  const toast = useCallback((message: string) => {
    setToast(message);
    window.clearTimeout(timer.current);
    timer.current = window.setTimeout(() => setToast(null), 2200);
  }, []);
  useEffect(() => () => window.clearTimeout(timer.current), []);
  const close = useCallback(() => setSheet(null), []);
  const value = useMemo(() => ({ sheet, open: setSheet, close, toast, toastMessage }), [sheet, close, toast, toastMessage]);
  return <Ctx.Provider value={value}>{children}</Ctx.Provider>;
}

export function Toast() {
  const { toastMessage } = useUI();
  return (
    <div aria-live="polite" role="status">
      {toastMessage && <div className="toast">{toastMessage}</div>}
    </div>
  );
}

/** Bottom sheet: scrim (tap closes), grabber, content. Escape closes; focus moves into the sheet. */
export function Sheet({ label, onClose, children }: { label: string; onClose: () => void; children: ReactNode }) {
  const ref = useRef<HTMLDivElement>(null);
  useEffect(() => {
    const previous = document.activeElement as HTMLElement | null;
    ref.current?.focus();
    const onKey = (e: KeyboardEvent) => {
      if (e.key === "Escape") onClose();
    };
    document.addEventListener("keydown", onKey);
    return () => {
      document.removeEventListener("keydown", onKey);
      previous?.focus?.();
    };
  }, [onClose]);
  return (
    <>
      <button className="scrim" aria-label="Close" tabIndex={-1} onClick={onClose} />
      <div ref={ref} className="sheet" role="dialog" aria-modal="true" aria-label={label} tabIndex={-1}>
        <span className="sheet-grab" aria-hidden="true" />
        {children}
      </div>
    </>
  );
}

/** Settings-style switch row: title, sub line, 46×28 track. */
export function ToggleRow(props: { title: string; sub?: string | undefined; on: boolean; disabled?: boolean; onChange: (on: boolean) => void }) {
  return (
    <button type="button" className="toggle-row" role="switch" aria-checked={props.on} disabled={props.disabled}
            onClick={() => props.onChange(!props.on)}>
      <span className="toggle-text">
        <span className="t">{props.title}</span>
        {props.sub && <span className="s">{props.sub}</span>}
      </span>
      <span className={`toggle${props.on ? " on" : ""}`} aria-hidden="true" />
    </button>
  );
}
