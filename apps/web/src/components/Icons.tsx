import type { ReactNode } from "react";

/** Line icons for the tab bar and list rows. Decorative: the visible label always carries the meaning. */
type P = { className?: string };

function Svg({ className, children }: P & { children: ReactNode }) {
  return (
    <svg className={className} viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth={1.9}
         strokeLinecap="round" strokeLinejoin="round" aria-hidden="true" focusable="false">
      {children}
    </svg>
  );
}

export const CarIcon = (p: P) => (
  <Svg {...p}>
    <path d="M5 16.5h14M4 13.5l1.7-4.6A2 2 0 0 1 7.6 7.5h8.8a2 2 0 0 1 1.9 1.4l1.7 4.6" />
    <path d="M3.5 13.5h17v4a1 1 0 0 1-1 1h-1.5a1 1 0 0 1-1-1v-1h-10v1a1 1 0 0 1-1 1H4.5a1 1 0 0 1-1-1z" />
    <circle cx="7.5" cy="14.8" r="0.6" /><circle cx="16.5" cy="14.8" r="0.6" />
  </Svg>
);

export const CalendarIcon = (p: P) => (
  <Svg {...p}>
    <rect x="4" y="5.5" width="16" height="14.5" rx="2" />
    <path d="M4 10h16M8.5 3.5v4M15.5 3.5v4" />
    <path d="M8 13.5h.01M12 13.5h.01M16 13.5h.01M8 16.5h.01M12 16.5h.01" strokeWidth={2.2} />
  </Svg>
);

export const FamilyIcon = (p: P) => (
  <Svg {...p}>
    <circle cx="9" cy="8.5" r="3" />
    <path d="M3.5 19.5a5.5 5.5 0 0 1 11 0" />
    <circle cx="16.5" cy="9.5" r="2.4" />
    <path d="M15.5 14.2a4.6 4.6 0 0 1 5 5.3" />
  </Svg>
);

export const BellIcon = (p: P) => (
  <Svg {...p}>
    <path d="M6.5 16.5V11a5.5 5.5 0 0 1 11 0v5.5l1.5 1.5H5z" />
    <path d="M10 20.5a2.2 2.2 0 0 0 4 0" />
  </Svg>
);

export const GearIcon = (p: P) => (
  <Svg {...p}>
    <circle cx="12" cy="12" r="3" />
    <path d="M12 3.5v2M12 18.5v2M3.5 12h2M18.5 12h2M6 6l1.4 1.4M16.6 16.6 18 18M6 18l1.4-1.4M16.6 7.4 18 6" />
  </Svg>
);

export const ChevronRight = (p: P) => (
  <Svg {...p}><path d="m9.5 6 6 6-6 6" /></Svg>
);

export const ChevronDown = (p: P) => (
  <Svg {...p}><path d="m6 9.5 6 6 6-6" /></Svg>
);

export const ChevronLeft = (p: P) => (
  <Svg {...p}><path d="m14.5 6-6 6 6 6" /></Svg>
);

export const PlusIcon = (p: P) => (
  <Svg {...p}><path d="M12 5.5v13M5.5 12h13" /></Svg>
);

export const ClockIcon = (p: P) => (
  <Svg {...p}><circle cx="12" cy="12" r="8" /><path d="M12 7.5V12l3 2" /></Svg>
);

export const PinIcon = (p: P) => (
  <Svg {...p}><path d="M12 20.5s6-5.4 6-10.5a6 6 0 0 0-12 0c0 5.1 6 10.5 6 10.5z" /><circle cx="12" cy="10" r="2.2" /></Svg>
);

export const PersonIcon = (p: P) => (
  <Svg {...p}><circle cx="12" cy="8.5" r="3.5" /><path d="M5 20a7 7 0 0 1 14 0" /></Svg>
);

export const InfoIcon = (p: P) => (
  <Svg {...p}><circle cx="12" cy="12" r="8.5" /><path d="M12 11v5.5M12 7.8v.01" /></Svg>
);

export const MoonIcon = (p: P) => (
  <Svg {...p}><path d="M19 14.5A7.5 7.5 0 0 1 9.5 5a7.5 7.5 0 1 0 9.5 9.5z" /></Svg>
);

export const LockIcon = (p: P) => (
  <Svg {...p}><rect x="5.5" y="10.5" width="13" height="9.5" rx="2" /><path d="M8.5 10.5V8a3.5 3.5 0 0 1 7 0v2.5" /></Svg>
);

export const TrashIcon = (p: P) => (
  <Svg {...p}><path d="M5 7h14M10 7V5h4v2M7 7l.8 12.5a1 1 0 0 0 1 .9h6.4a1 1 0 0 0 1-.9L17 7M10.5 11v6M13.5 11v6" /></Svg>
);

export const DownloadIcon = (p: P) => (
  <Svg {...p}><path d="M12 4.5v10M7.5 10.5 12 15l4.5-4.5M5 19.5h14" /></Svg>
);

export const ExitIcon = (p: P) => (
  <Svg {...p}><path d="M14 4.5H6.5a1 1 0 0 0-1 1v13a1 1 0 0 0 1 1H14M10 12h10M16.5 8.5 20 12l-3.5 3.5" /></Svg>
);

export const CheckCircleIcon = (p: P) => (
  <Svg {...p}><circle cx="12" cy="12" r="8.5" /><path d="m8.5 12.2 2.4 2.4 4.6-4.9" /></Svg>
);

export const MenuIcon = (p: P) => (
  <Svg {...p}>
    <path d="M7 3.5v6.5M5 3.5v4.5a2 2 0 0 0 4 0V3.5M7 10v10.5" />
    <path d="M17 20.5V3.5c-2.2 1.3-3.5 3.6-3.5 6.5v3.5H17" />
  </Svg>
);

export const XIcon = (p: P) => (
  <Svg {...p}><path d="M6 6l12 12M18 6L6 18" /></Svg>
);

export const CheckIcon = (p: P) => (
  <Svg {...p}><path d="m5 12.5 4.5 4.5L19 7.5" /></Svg>
);

/** Gym: a dumbbell. */
export const DumbbellIcon = (p: P) => (
  <Svg {...p}>
    <path d="M8.5 12h7" />
    <rect x="5" y="7" width="3.5" height="10" rx="1" />
    <rect x="15.5" y="7" width="3.5" height="10" rx="1" />
    <path d="M3 10v4M21 10v4" />
  </Svg>
);

/** Padel: a round paddle and a ball. */
export const RacketIcon = (p: P) => (
  <Svg {...p}>
    <circle cx="10" cy="10" r="6.5" />
    <path d="m14.6 14.6 5 5" strokeWidth={3} />
    <path d="M8 8h.01M12 8h.01M8 12h.01M12 12h.01M10 10h.01" strokeWidth={2.4} />
    <circle cx="19.5" cy="5" r="1.7" />
  </Svg>
);

/** Errand: a shopping bag. */
export const BagIcon = (p: P) => (
  <Svg {...p}>
    <path d="M5.5 8.5h13l-1 11a1 1 0 0 1-1 .9h-9a1 1 0 0 1-1-.9z" />
    <path d="M9 10.5V7a3 3 0 0 1 6 0v3.5" />
  </Svg>
);

/** Documents: a folder. */
export const FolderIcon = (p: P) => (
  <Svg {...p}><path d="M3.5 7.5a1.5 1.5 0 0 1 1.5-1.5h4.2l2 2.2H19a1.5 1.5 0 0 1 1.5 1.5v8.3a1.5 1.5 0 0 1-1.5 1.5H5a1.5 1.5 0 0 1-1.5-1.5z" /></Svg>
);

/** Documents: a page with a folded corner. */
export const FileIcon = (p: P) => (
  <Svg {...p}><path d="M7 3.5h7l4.5 4.5v11a1.5 1.5 0 0 1-1.5 1.5H7a1.5 1.5 0 0 1-1.5-1.5V5A1.5 1.5 0 0 1 7 3.5z" /><path d="M13.5 3.5V8.5h5" /></Svg>
);

export const UploadIcon = (p: P) => (
  <Svg {...p}><path d="M12 15.5v-11M7.5 9 12 4.5 16.5 9M5 19.5h14" /></Svg>
);

export const ExternalIcon = (p: P) => (
  <Svg {...p}><path d="M13.5 5.5h5v5M18.5 5.5 11 13M16.5 14v4a1.5 1.5 0 0 1-1.5 1.5H6A1.5 1.5 0 0 1 4.5 18V9A1.5 1.5 0 0 1 6 7.5h4" /></Svg>
);
