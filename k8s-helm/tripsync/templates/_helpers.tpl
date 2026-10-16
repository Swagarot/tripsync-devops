{{- /*
Environment shared by the backend container and its migrate init container,
so the two can't drift apart.
*/ -}}
{{- define "tripsync.backendEnv" -}}
- name: POSTGRES_HOST
  value: tripsync-postgres
- name: POSTGRES_DB
  value: tripsync
- name: POSTGRES_USER
  value: tripsync
- name: POSTGRES_PASSWORD
  valueFrom:
    secretKeyRef:
      name: tripsync-secrets
      key: postgres-password
- name: JWT_SECRET_KEY
  valueFrom:
    secretKeyRef:
      name: tripsync-secrets
      key: jwt-secret-key
{{- end }}
