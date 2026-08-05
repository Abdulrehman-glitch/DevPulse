import { CircleAlert, RefreshCw } from "lucide-react";

export function ErrorState({
  title = "Workspace data is unavailable",
  message,
  onRetry,
}: {
  title?: string;
  message: string;
  onRetry: () => void;
}) {
  return (
    <section className="error-state" role="alert">
      <CircleAlert size={26} />
      <div>
        <h2>{title}</h2>
        <p>{message}</p>
      </div>
      <button className="button" onClick={onRetry}>
        <RefreshCw size={15} /> Try again
      </button>
    </section>
  );
}
