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
# OpenRouteService key for routes/travel times. Created by hand on k3s (not in
# git): kubectl -n tripsync create secret generic openrouteservice
# --from-literal=api-key="..."  optional: true = if the Secret doesn't exist
# (EKS), the pod still starts and the app shows straight lines instead.
- name: ORS_API_KEY
  valueFrom:
    secretKeyRef:
      name: openrouteservice
      key: api-key
      optional: true
{{- end }}
