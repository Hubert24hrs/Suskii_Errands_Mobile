export default function NotFound() {
  return (
    <main className="mx-auto flex min-h-screen w-full max-w-3xl flex-col items-center justify-center px-lg text-center">
      <h1 className="text-headline-medium text-ink-primary dark:text-ink-dark-primary">
        Page not found
      </h1>
      <a
        href="/"
        className="mt-xxl rounded-md bg-brand-primary px-xl py-md text-label-large text-brand-on-primary transition-colors duration-normal ease-standard hover:bg-brand-primary-strong"
      >
        Back to dashboard
      </a>
    </main>
  );
}
