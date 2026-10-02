# MongoDB Replica Set Helm Chart

Ein Helm Chart für ein MongoDB Replica Set mit drei Mitgliedern in Kubernetes.

## Architektur

- Ein StatefulSet verwaltet die drei Pods `mongodb-0`, `mongodb-1` und `mongodb-2`.
- Der Headless-Service `mongodb-headless` stellt stabile DNS-Namen für die Pods bereit.
- Jeder Pod erhält ein eigenes PersistentVolumeClaim für seine Daten.
- Jeder Pod verwendet ein eigenes TLS-Zertifikat aus einem Kubernetes-Secret.
- Die Zertifikate werden von einer gemeinsamen CA signiert.
- Die interne Replica-Set-Authentifizierung verwendet einen gemeinsamen Keyfile aus einem Kubernetes-Secret.
- Die Admin-Zugangsdaten werden aus dem vorhandenen Kubernetes-Secret `mongodb-auth` gelesen.
- Ein Helm-Bootstrap-Job initialisiert das Replica Set.

## Unterstützte Anpassungen

Die Werte in `mongodb-chart/values.yaml` erlauben unter anderem Anpassungen für:

- Replica-Set-Name und Mitgliederzahl bei der Erstinstallation
- MongoDB-Image, Version und Pull-Richtlinie
- CPU- und Speicheranforderungen sowie Limits
- Größe, Zugriffsmuster und StorageClass der Daten- und Backup-Volumes
- Kubernetes-Service-Port
- Pod-Annotations, Node-Selector, Affinity und Tolerations
- Topologieverteilung über Nodes
- Namen und Schlüssel der TLS-, Admin- und internen Auth-Secrets
- Backup-Zeitplan, Zeitzone und Aufbewahrungsdauer
- gezielten oder vollständigen Restore

Für jedes Mitglied muss ein TLS-Secret unter `tls.memberSecrets.mongodb-<ordinal>` eingetragen sein. Das Zertifikat muss den DNS-Namen des jeweiligen Pods im gewählten Release und Namespace enthalten. Eine Änderung von `replicaSet.members` nach der Erstinstallation konfiguriert ein bestehendes Replica Set nicht automatisch um; dafür ist eine kontrollierte MongoDB-Rekonfiguration erforderlich.

## Sicherheit

TLS-Zertifikate, private Schlüssel, Keyfiles und Passwortdateien werden außerhalb des Charts bereitgestellt. Sie gehören nicht ins Git-Repository. Das Chart verweist auf Kubernetes-Secrets, deren Inhalte nicht in `values.yaml` eingetragen werden.

Die Zertifikate müssen DNS-Namen für alle drei Pods im verwendeten Release und Namespace enthalten.

## Backups und Wiederherstellung

Der Chart erstellt standardmäßig täglich um 03:00 Uhr (`Europe/Zurich`) ein Backup. Archive liegen auf einem separaten persistenten Volume (standardmäßig 20 GiB). Die Aufbewahrung beträgt standardmäßig 30 Tage.

Der zeitgesteuerte CronJob wurde durch vorübergehendes Ausführen jede Minute geprüft. Die 30-Tage-Löschregel wurde mit einer 31 Tage alten Testdatei geprüft.

Restores sind standardmäßig deaktiviert. Für einen Datenbank-Restore müssen Archivdatei und Datenbankname gesetzt sein. Ein vollständiger Restore erfordert `restore.fullRestore=true`. Ein vollständiger Dump mit Oplog wurde in einer separaten, temporären MongoDB-Testinstanz wiederhergestellt und der Testdatensatz anschließend geprüft. Ein Chart-Restore-Job wurde nicht auf dem produktiven Replica Set ausgeführt.

Das Backup-Volume bleibt innerhalb des Kubernetes-Clusters. Für Schutz vor Verlust des Clusters oder Speichers müssen wichtige Archive zusätzlich außerhalb des Clusters gesichert werden.

## Resource allocation and pod placement

CPU- und Speicheranforderungen sowie Limits sind unter `resources` konfigurierbar. Kubernetes verwendet die Anforderungen beim Planen der Pods und setzt die Limits während des Betriebs durch.

Die Topologie-Regel verteilt MongoDB-Mitglieder bevorzugt über Nodes. Sie wurde in einem Drei-Node-Minikupe-Testcluster geprüft: alle drei Pods lagen auf unterschiedlichen Nodes. Ein Mitgliedsausfall und der Ausfall eines Worker-Nodes führten jeweils zur Wahl eines neuen Primary; nach Neustart trat das Mitglied wieder als Secondary bei. Die Minikube-Nodes sind Docker-Container auf demselben Rechner und belegen keine Ausfallsicherheit über mehrere physische Server.

## HashiCorp Vault

Eine lokale Demo-Integration mit Vault KV v2 und dem Vault Secrets Operator ist eingerichtet. VSO synchronisiert Admin-Zugangsdaten, Replica-Set-Keyfile und individuelle TLS-Zertifikate in die Kubernetes-Secrets, die das Chart erwartet. Vault ist dabei die Quelle der Werte; Kubernetes-Secrets existieren weiterhin und benötigen passende Kubernetes-RBAC-Rechte.

Die TLS-Synchronisierungen lösen bei einer Zertifikatsänderung einen StatefulSet-Rollout aus. Eine Passwortänderung in Vault ändert das gespeicherte MongoDB-Benutzerpasswort nicht automatisch. Das Keyfile muss wegen seiner gemeinsamen Nutzung durch alle Replica-Set-Mitglieder kontrolliert rotiert werden.

Die getestete lokale Vault-Installation lief im Dev-Modus mit In-Memory-Speicher. Sie ist nur für die Minikube-Demo gedacht; bei einem Neustart gehen Vault-Daten verloren. Produktionsspeicher, TLS zu Vault, Bootstrap/Unseal, Disaster-Recovery und automatisierte koordinierte Rotation sind noch offen. Details und Manifeste stehen in [`vault/README.md`](vault/README.md) und [`vault/vso-mongodb.yaml`](vault/vso-mongodb.yaml).
