export function Logo({ className = "h-8 w-8" }: { className?: string }) {
  return (
    <svg
      viewBox="0 0 256 256"
      className={className}
      fill="none"
      xmlns="http://www.w3.org/2000/svg"
      aria-label="Vernier"
    >
      <defs>
        <linearGradient id="vernier-g" x1="48" y1="208" x2="208" y2="64" gradientUnits="userSpaceOnUse">
          <stop stopColor="#5eead4" />
          <stop offset="1" stopColor="#8b8bf7" />
        </linearGradient>
      </defs>
      <rect width="256" height="256" rx="60" fill="#0B0D14" />
      <path
        d="M52 172 L204 152"
        stroke="rgba(255,255,255,0.3)"
        strokeWidth="10"
        strokeLinecap="round"
        strokeDasharray="1 26"
      />
      <path d="M52 190 C 116 186 168 154 204 88" stroke="url(#vernier-g)" strokeWidth="20" strokeLinecap="round" />
      <circle cx="204" cy="88" r="15" fill="#8b8bf7" />
    </svg>
  );
}
