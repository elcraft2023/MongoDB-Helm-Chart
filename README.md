# MongoDB Helm Chart

Ein anpassbares Helm Chart für ein MongoDB Replica Set auf Kubernetes. Es richtet standardmäßig drei MongoDB-Mitglieder mit TLS, interner Replica-Set-Authentifizierung, dauerhaftem Speicher und optionalen Backups ein.

> **Hinweis zu Geheimnissen:** Keine echten Passwörter, privaten Schlüssel, Zertifikate oder Kubernetes-Secret-Inhalte in dieses Repository oder in `values.yaml` eintragen. `certs/` ist durch `.gitignore` ausgeschlossen. Die lokalen Dateien dort können außerdem veraltet sein; maßgeblich ist die Secret-Konfiguration im Cluster beziehungsweise in Vault.

## Inhalt

- [Architektur und Funktionen](#architektur-und-funktionen)
- [Voraussetzungen und Start](#voraussetzungen-und-start)
- [Anpassungen](#anpassungen)
- [Secrets und Passwörter](#secrets-und-passwörter)
- [Backups und Wiederherstellung](#backups-und-wiederherstellung)
- [Ressourcen und mehrere Server](#ressourcen-und-mehrere-server)
- [HashiCorp Vault](#hashicorp-vault)
- [Prüfungen und bekannte Grenzen](#prüfungen-und-bekannte-grenzen)

## Architektur und Funktionen

Das Chart enthält:

- Einen `StatefulSet` für standardmäßig drei MongoDB-Pods (`mongodb-0` bis `mongodb-2`).
- Ein Headless Service für stabile DNS-Namen der Pods.
- Ein eigenes dauerhaftes Volume pro MongoDB-Pod.
- Individuelle TLS-Zertifikate pro Mitglied und eine gemeinsame CA.
- Eine Keyfile-basierte interne Authentifizierung zwischen Replica-Set-Mitgliedern.
- Einen Bootstrap-Job, der das Replica Set initialisiert.
- Einen optionalen Backup-CronJob mit eigenem persistentem Backup-Volume.
- Einen optionalen Restore-Job, der ein ausgewähltes Archiv wiederherstellt.
- Konfigurierbare Ressourcen und Regeln zur Pod-Platzierung.

## Voraussetzungen und Start

Benötigt werden ein Kubernetes-Cluster sowie `kubectl` und Helm. Für den lokalen Versuch wurde Minikube verwendet.

Die benötigten TLS-, Authentifizierungs- und Keyfile-Secrets müssen vor dem Installieren im Ziel-Namespace vorhanden sein. Alternativ kann Vault Secrets Operator sie aus Vault bereitstellen; warte dann, bis die zugehörigen `VaultStaticSecret`-Ressourcen als synchronisiert und bereit angezeigt werden.

```bash
minikube start
kubectl create namespace mongodb
helm lint ./mongodb-chart
helm upgrade --install mongodb ./mongodb-chart \
  --namespace mongodb \
  --wait \
  --timeout 10m
```

Status prüfen:

```bash
kubectl get pods,services,pvc,cronjob -n mongodb
kubectl rollout status statefulset/mongodb -n mongodb --timeout=5m
```

Für ein bereits laufendes Minikube-Profil genügt `minikube start`. Bei einem anderen Release-Namen, Namespace oder DNS-Namen müssen die Zertifikate passende Subject Alternative Names enthalten.

## Anpassungen

Die Standardwerte und ihre Kommentare stehen in [`mongodb-chart/values.yaml`](mongodb-chart/values.yaml). Änderungen lassen sich in einer eigenen Werte-Datei bündeln, zum Beispiel `my-values.yaml`, und mit `-f my-values.yaml` übergeben. Geheimnisse gehören nicht in diese Datei.

Vor einer Installation kann Helm die resultierenden Kubernetes-Ressourcen anzeigen:

```bash
helm template mongodb ./mongodb-chart --namespace mongodb -f my-values.yaml
```

Wichtige anpassbare Werte:

| Bereich | Werte und Zweck |
|---|---|
| Namen | `nameOverride`, `fullnameOverride` ändern die Chart- und Ressourcennamen. |
| Replica Set | `replicaSet.name` setzt den Replica-Set-Namen; `replicaSet.members` legt die Mitgliederzahl fest. |
| MongoDB-Image | `image.repository`, `image.tag`, `image.pullPolicy` wählen Image und Abrufverhalten. |
| TLS | `tls.enabled` muss aktiviert bleiben; `tls.memberSecrets` ordnet jedem Pod sein TLS-Secret zu. |
| Anmeldung | `auth.existingSecret`, `auth.usernameKey`, `auth.passwordKey` wählen Kubernetes-Secret und Daten-Schlüssel. |
| Interne Anmeldung | `internalAuth.existingSecret`, `internalAuth.keyFileKey` bestimmen Secret und Schlüssel für die Replica-Set-Keyfile. |
| Datenvolumes | `storage.size`, `storage.storageClassName`, `storage.accessModes` konfigurieren die Daten-PVCs. |
| Service | `service.port` ändert den Service-Port. |
| Ressourcen | `resources.requests` und `resources.limits` setzen CPU- und Speicheranforderungen beziehungsweise Grenzen. |
| Platzierung | `nodeSelector`, `tolerations`, `affinity`, `podAnnotations` und `topologySpread` beeinflussen die Pod-Platzierung und Metadaten. |
| Backups | `backup.enabled`, `backup.schedule`, `backup.timeZone`, `backup.retentionDays` und `backup.storage` steuern Sicherungen. |
| Wiederherstellung | `restore.enabled`, `restore.archiveFile`, `restore.database`, `restore.fullRestore` steuern einen Restore-Job. |

Beispiel für eine Vorschau mit eigenen Ressourcen, Speichergröße und Sicherungszeit:

```bash
helm template mongodb ./mongodb-chart --namespace mongodb \
  --set storage.size=15Gi \
  --set resources.requests.cpu=600m \
  --set resources.requests.memory=768Mi \
  --set-string backup.schedule="15 4 * * *"
```

Ein bereits initialisiertes Replica Set lässt sich nicht gefahrlos durch bloßes Ändern von `replicaSet.members` skalieren. Für zusätzliche Mitglieder braucht es passende Zertifikate und eine kontrollierte Replica-Set-Konfigurationsänderung. Außerdem sind Änderungen am unveränderlichen `StatefulSet`-Selector nicht per normalem Helm-Upgrade möglich.

## Secrets und Passwörter

Standardmäßig erwartet das Chart folgende Kubernetes-Secrets im selben Namespace wie MongoDB:

| Kubernetes-Secret | Schlüssel | Inhalt |
|---|---|---|
| `mongodb-auth` | `username`, `password` | MongoDB-Administrator-Anmeldung |
| `mongodb-internal-auth` | `keyfile` | Gemeinsamer Schlüssel für die interne Replica-Set-Anmeldung |
| `mongo-0-tls`, `mongo-1-tls`, `mongo-2-tls` | `tls.crt`, `tls.key`, `ca.crt` | Zertifikat, privater Schlüssel und CA je Mitglied |

Die Namen und Schlüssel lassen sich über `auth`, `internalAuth` und `tls.memberSecrets` ändern. Die Secret-Werte stehen nicht in `values.yaml`. Das Chart liest sie zur Laufzeit aus Kubernetes-Secrets. Kubernetes-Secrets sind dennoch kein Passwortmanager: Zugriffsrechte auf Secrets oder auf die laufenden Pods können den Zugriff auf die Werte ermöglichen. Der Zugriff sollte daher über RBAC eingeschränkt werden.

### Woher kommen die Werte in dieser Installation?

Wenn Vault Secrets Operator eingerichtet ist, liegen die maßgeblichen Werte in Vault KV v2 und werden als Kubernetes-Secrets synchronisiert:

| Vault-Pfad | Ziel im Kubernetes-Cluster |
|---|---|
| `secret/mongodb/auth` | `mongodb-auth` mit `username` und `password` |
| `secret/mongodb/internal-auth` | `mongodb-internal-auth` mit `keyfile` |
| `secret/mongodb/tls/mongo-0` | `mongo-0-tls` |
| `secret/mongodb/tls/mongo-1` | `mongo-1-tls` |
| `secret/mongodb/tls/mongo-2` | `mongo-2-tls` |

Die TLS-Werte im Vault-Pfad verwenden die Schlüssel `tls.crt`, `tls.key` und `ca.crt`. Die zugehörigen `VaultStaticSecret`-Ressourcen sind in `vault/vso-mongodb.yaml` beschrieben. Der Status kann ohne Ausgabe der geheimen Inhalte kontrolliert werden:

```bash
kubectl --context=minikube get vaultstaticsecrets -n mongodb
```

### Administratorpasswort ändern

Eine Passwortänderung hat zwei Schritte: MongoDB muss das neue Passwort für den Benutzer speichern, und anschließend muss der Vault-Wert aktualisiert werden. Nur das Kubernetes-Secret oder Vault zu ändern aktualisiert das in MongoDB gespeicherte Passwort nicht.

1. Erzeuge ein neues ASCII-Passwort lokal und halte es aus Git heraus. Beispiel: `openssl rand -hex 32 > certs/admin-password.txt`.
2. Verbinde dich mit dem derzeit gültigen Passwort über `mongosh` zur Primary und ändere das MongoDB-Passwort interaktiv mit `db.getSiblingDB("admin").changeUserPassword("admin", passwordPrompt())`. `passwordPrompt()` wartet auf die Eingabe und schreibt das Passwort nicht in den Befehl.
3. Aktualisiere danach den Vault-Eintrag `secret/mongodb/auth`, Feld `password`, mit demselben neuen Wert. Verwende für den Vault-Zugriff die lokale Entwicklungsanleitung in `vault/README.md`; dort steht auch, wie die Eingabe ohne Anzeige in der Shell erfolgt.
4. Warte, bis `mongodb-auth-from-vault` wieder synchronisiert und bereit ist. Prüfe anschließend die Anmeldung mit `mongosh --password`, damit die Eingabeaufforderung das Passwort verdeckt.
5. Lösche die temporäre Passwortdatei nach erfolgreicher Prüfung und entferne das Passwort aus der Zwischenablage.

Das lokale Demo-Vault ist im Entwicklungsmodus mit In-Memory-Speicher eingerichtet. Ein Neustart kann die dort gespeicherten Werte löschen. Es ist nicht für produktive Geheimnisverwaltung geeignet. Für produktive Nutzung muss Vault mit dauerhaftem Speicher, geeigneter Authentifizierung, TLS und gesicherter Entsiegelung konfiguriert werden.

## Backups und Wiederherstellung

Backups sind standardmäßig aktiviert. Der CronJob erstellt täglich um 03:00 Uhr in der Zeitzone `Europe/Zurich` ein komprimiertes MongoDB-Archiv. Die Dateien liegen auf einem separaten Backup-PVC, standardmäßig mit 20 GiB. Backups werden nach 30 Tagen gelöscht. Zeitplan, Zeitzone, Aufbewahrungsdauer und PVC sind über `backup.*` anpassbar.

Ein manuelles Backup lässt sich aus dem CronJob erstellen:

```bash
kubectl create job mongodb-backup-manual \
  --from=cronjob/mongodb-backup \
  -n mongodb
kubectl logs job/mongodb-backup-manual -n mongodb
```

Der Job muss erfolgreich mit `Complete` enden. `0/1 Completed` bei seinem Pod ist normal: Der Einmal-Container ist beendet; entscheidend ist der Jobstatus `Complete` und der erfolgreiche Logeintrag „Backup erstellt“.

Die Archive liegen auf dem PVC `mongodb-backups` unter `/backups`. Zum Anzeigen der Dateien kann ein temporärer Pod das PVC mounten. Danach den temporären Pod wieder löschen. Ein Backup auf demselben Cluster schützt nicht vor Verlust des Clusters oder seines Speichers; wichtige Archive zusätzlich außerhalb des Clusters sichern.

### Datenbank wiederherstellen

Ein datenbankspezifischer Restore benötigt den Archivdateinamen und einen Datenbanknamen:

```bash
helm upgrade --install mongodb ./mongodb-chart \
  --namespace mongodb --no-hooks \
  --set restore.enabled=true \
  --set restore.fullRestore=false \
  --set-string restore.database=backup_test \
  --set-string restore.archiveFile=mongodb-YYYYMMDDTHHMMSSZ.archive.gz
```

### Vollständige Wiederherstellung

Für eine vollständige Wiederherstellung wird `restore.fullRestore=true` gesetzt und kein Datenbankname angegeben:

```bash
helm upgrade --install mongodb ./mongodb-chart \
  --namespace mongodb --no-hooks \
  --set restore.enabled=true \
  --set restore.fullRestore=true \
  --set-string restore.archiveFile=mongodb-YYYYMMDDTHHMMSSZ.archive.gz
```

Der Restore verwendet `--drop` und kann vorhandene Daten überschreiben. Die Eingaben werden durch das Template geprüft: Der Archivwert muss ein Dateiname ohne Pfad sein; Datenbank-Restore und vollständiger Restore dürfen nicht gleichzeitig gewählt werden. Ein Restore-Job sollte nur nach Prüfung des Archivs und mit klarer Kenntnis des Ziels gestartet werden.

Restore anschließend wieder deaktivieren:

```bash
helm upgrade --install mongodb ./mongodb-chart \
  --namespace mongodb --no-hooks \
  --set restore.enabled=false
```

## Ressourcen und mehrere Server

Die Ressourcenverteilung erfolgt durch den Kubernetes-Scheduler anhand von `resources.requests`, `resources.limits` und den Platzierungsregeln. Das Chart enthält keinen eigenen Hardware-Manager, der Serverressourcen dynamisch zwischen Pods aufteilt.

Die Topology-Spread-Regel versucht, MongoDB-Pods über Kubernetes-Nodes zu verteilen. Mit einem Node, wie beim normalen Minikube-Profil, laufen alle drei Pods auf demselben Node. Ein Minikube-Mehrknotenprofil kann Verteilung und Failover testen, stellt aber keine drei unabhängigen physischen Server dar.

## HashiCorp Vault

Die optionale Vault-Demo verwendet Vault, Vault Secrets Operator, Kubernetes-Authentifizierung und Vault KV v2. Der Operator synchronisiert Zugangsdaten, Keyfile und TLS-Material aus Vault in Kubernetes-Secrets, die das Helm Chart referenziert. Die MongoDB-Pods lesen die Werte weiterhin aus Kubernetes-Secrets.

Die Entwicklungsinstallation und die dazugehörigen Ressourcen befinden sich in `vault/README.md`, `vault/vso-mongodb.yaml` und `vault/mongodb-read.hcl`. Das Dev-Vault nutzt In-Memory-Speicher und einen Demo-Root-Token. Diese Konfiguration dient nur lokalen Tests und darf nicht als produktive Vorlage eingesetzt werden. Eine Secret-Rotation in Vault aktualisiert nicht automatisch das bereits in MongoDB gespeicherte Administratorpasswort; die Datenbank und Vault müssen koordiniert aktualisiert werden.

## Prüfungen und bekannte Grenzen

Im lokalen Minikube-Setup wurden Chart-Rendering und Anpassungen, Replica-Set-Status, Neustart eines Mitglieds, Backup-Erstellung, Aufbewahrung, datenbankspezifischer Restore, vollständiger Restore in einer isolierten Testinstanz sowie die Verteilung auf drei Minikube-Nodes geprüft. Die vollständige Wiederherstellung wurde isoliert getestet, um die aktive Datenbank nicht zu überschreiben.

Die Vault-Demo wurde auf Synchronisierung von Authentifizierung, Keyfile und TLS-Secrets geprüft. Vault läuft dabei mit flüchtigem Dev-Speicher. Ein produktiver Vault-Betrieb, produktive Schlüsselrotation, externe Backup-Speicherung und ein eigenes automatisches Kapazitätsmanagement sind nicht Teil dieses Charts.
