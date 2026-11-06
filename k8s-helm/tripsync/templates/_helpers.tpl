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
{{- if and .Values.garage.enabled .Values.s3.enabled }}
{{- fail "garage.enabled and s3.enabled: pick one photo store" }}
{{- end }}
{{- if .Values.garage.enabled }}
# Photo storage (Garage, S3 API). Without these the backend turns photo
# uploads off and everything else keeps working.
- name: S3_ENDPOINT
  value: http://tripsync-garage:3900
- name: S3_BUCKET
  value: tripsync-photos
- name: S3_REGION
  value: garage
- name: S3_ACCESS_KEY_ID
  valueFrom:
    secretKeyRef:
      name: tripsync-secrets
      key: s3-access-key-id
- name: S3_SECRET_ACCESS_KEY
  valueFrom:
    secretKeyRef:
      name: tripsync-secrets
      key: s3-secret-access-key
- name: GARAGE_ADMIN_URL
  value: http://tripsync-garage:3903
- name: GARAGE_ADMIN_TOKEN
  valueFrom:
    secretKeyRef:
      name: tripsync-secrets
      key: garage-admin-token
{{- else if .Values.s3.enabled }}
# Photo storage in AWS S3 (EKS). No endpoint and no key: boto3 gets the
# pod's IAM role from EKS Pod Identity.
- name: S3_BUCKET
  value: {{ required "s3.bucket is required when s3.enabled" .Values.s3.bucket | quote }}
- name: S3_REGION
  value: {{ required "s3.region is required when s3.enabled" .Values.s3.region | quote }}
{{- end }}
{{- end }}
