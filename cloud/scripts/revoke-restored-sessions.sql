UPDATE public.sessions
SET revoked_at = CURRENT_TIMESTAMP
WHERE revoked_at IS NULL;
