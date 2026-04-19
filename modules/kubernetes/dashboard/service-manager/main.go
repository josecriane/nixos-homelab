package main

import (
	"crypto/tls"
	"embed"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"sort"
	"strings"
	"sync"
	"time"
)

//go:embed index.html
var staticFiles embed.FS

type Config struct {
	GroupNames map[string]string `json:"groupNames"`
	NoStop     []string          `json:"noStop"`
	Hide       []string          `json:"hide"`
}

type ServiceStatus struct {
	DisplayName string `json:"displayName"`
	Name        string `json:"name"`
	Namespace   string `json:"namespace"`
	Group       string `json:"group"`
	Kind        string `json:"kind"`
	CanStop     bool   `json:"canStop"`
	Replicas    int    `json:"replicas"`
	Ready       bool   `json:"ready"`
	RAMBytes    int64  `json:"ramBytes"`
}

type ServicesResponse struct {
	Services []ServiceStatus `json:"services"`
	RAMUsed  int64           `json:"ramUsed"`
	RAMTotal int64           `json:"ramTotal"`
}

type ScaleRequest struct {
	Namespace string `json:"namespace"`
	Name      string `json:"name"`
	Replicas  int    `json:"replicas"`
}

type GroupScaleRequest struct {
	Group    string `json:"group"`
	Replicas int    `json:"replicas"`
}

var (
	k8sHost string
	k8sHTTP *http.Client
	cfg     Config
	mu      sync.Mutex
)

func init() {
	k8sHost = "https://" + os.Getenv("KUBERNETES_SERVICE_HOST") + ":" + os.Getenv("KUBERNETES_SERVICE_PORT")
	tr := &http.Transport{
		TLSClientConfig: &tls.Config{InsecureSkipVerify: true},
	}
	k8sHTTP = &http.Client{Transport: tr, Timeout: 10 * time.Second}
}

func loadToken() string {
	data, err := os.ReadFile("/var/run/secrets/kubernetes.io/serviceaccount/token")
	if err != nil {
		log.Printf("Warning: cannot read SA token: %v", err)
		return ""
	}
	return strings.TrimSpace(string(data))
}

func loadConfig() {
	data, err := os.ReadFile("/config/services.json")
	if err != nil {
		log.Fatalf("Cannot read /config/services.json: %v", err)
	}
	if err := json.Unmarshal(data, &cfg); err != nil {
		log.Fatalf("Invalid services.json: %v", err)
	}
	log.Printf("Loaded config: %d group overrides, %d noStop rules, %d hidden", len(cfg.GroupNames), len(cfg.NoStop), len(cfg.Hide))
}

func k8sRequest(method, path string, body io.Reader) (*http.Response, error) {
	token := loadToken()
	req, err := http.NewRequest(method, k8sHost+path, body)
	if err != nil {
		return nil, err
	}
	req.Header.Set("Authorization", "Bearer "+token)
	if body != nil {
		if method == "PATCH" {
			req.Header.Set("Content-Type", "application/merge-patch+json")
		} else {
			req.Header.Set("Content-Type", "application/json")
		}
	}
	return k8sHTTP.Do(req)
}

func isHidden(ns string) bool {
	for _, h := range cfg.Hide {
		if h == ns {
			return true
		}
	}
	return false
}

func groupName(ns string) string {
	if name, ok := cfg.GroupNames[ns]; ok {
		return name
	}
	// Title case the namespace name
	parts := strings.Split(ns, "-")
	for i, p := range parts {
		if len(p) > 0 {
			parts[i] = strings.ToUpper(p[:1]) + p[1:]
		}
	}
	return strings.Join(parts, " ")
}

func isNoStop(ns, name string) bool {
	for _, rule := range cfg.NoStop {
		parts := strings.SplitN(rule, "/", 2)
		if len(parts) != 2 {
			continue
		}
		if parts[0] == ns && (parts[1] == "*" || parts[1] == name) {
			return true
		}
	}
	return false
}

func deploymentDisplayName(name string) string {
	parts := strings.Split(name, "-")
	for i, p := range parts {
		if len(p) > 0 {
			parts[i] = strings.ToUpper(p[:1]) + p[1:]
		}
	}
	return strings.Join(parts, " ")
}

type k8sWorkload struct {
	Kind     string `json:"kind"`
	Metadata struct {
		Name      string `json:"name"`
		Namespace string `json:"namespace"`
	} `json:"metadata"`
	Spec struct {
		Replicas *int `json:"replicas"`
	} `json:"spec"`
	Status struct {
		ReadyReplicas int `json:"readyReplicas"`
	} `json:"status"`
}

func listWorkloads(apiPath, kind string) []k8sWorkload {
	resp, err := k8sRequest("GET", apiPath, nil)
	if err != nil {
		return nil
	}
	defer resp.Body.Close()
	if resp.StatusCode != 200 {
		return nil
	}
	var result struct {
		Items []k8sWorkload `json:"items"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&result); err != nil {
		return nil
	}
	for i := range result.Items {
		result.Items[i].Kind = kind
	}
	return result.Items
}

func listAllWorkloads() []k8sWorkload {
	var all []k8sWorkload
	all = append(all, listWorkloads("/apis/apps/v1/deployments", "Deployment")...)
	all = append(all, listWorkloads("/apis/apps/v1/statefulsets", "StatefulSet")...)
	all = append(all, listWorkloads("/apis/apps/v1/daemonsets", "DaemonSet")...)
	return all
}

type podMetric struct {
	Namespace string
	PodName   string
	RAM       int64
}

func getPodMetricsAll() []podMetric {
	resp, err := k8sRequest("GET", "/apis/metrics.k8s.io/v1beta1/pods", nil)
	if err != nil {
		return nil
	}
	defer resp.Body.Close()
	if resp.StatusCode != 200 {
		return nil
	}
	var result struct {
		Items []struct {
			Metadata struct {
				Name      string `json:"name"`
				Namespace string `json:"namespace"`
			} `json:"metadata"`
			Containers []struct {
				Usage struct {
					Memory string `json:"memory"`
				} `json:"usage"`
			} `json:"containers"`
		} `json:"items"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&result); err != nil {
		return nil
	}
	var metrics []podMetric
	for _, pod := range result.Items {
		var ram int64
		for _, c := range pod.Containers {
			ram += parseK8sMemory(c.Usage.Memory)
		}
		metrics = append(metrics, podMetric{
			Namespace: pod.Metadata.Namespace,
			PodName:   pod.Metadata.Name,
			RAM:       ram,
		})
	}
	return metrics
}

func matchRAMToDeployments(pods []podMetric, deploymentNames map[string]bool) map[string]int64 {
	ramMap := make(map[string]int64)
	for _, pod := range pods {
		// Pod names follow: {deployment}-{replicaset-hash}-{pod-hash}
		// Try matching against known deployment names (longest match first)
		for key := range deploymentNames {
			parts := strings.SplitN(key, "/", 2)
			ns, depName := parts[0], parts[1]
			if pod.Namespace == ns && strings.HasPrefix(pod.PodName, depName+"-") {
				ramMap[key] += pod.RAM
				break
			}
		}
	}
	return ramMap
}

func parseK8sMemory(s string) int64 {
	s = strings.TrimSpace(s)
	if s == "" {
		return 0
	}
	if strings.HasSuffix(s, "Ki") {
		var v int64
		fmt.Sscanf(s, "%dKi", &v)
		return v * 1024
	}
	if strings.HasSuffix(s, "Mi") {
		var v int64
		fmt.Sscanf(s, "%dMi", &v)
		return v * 1024 * 1024
	}
	if strings.HasSuffix(s, "Gi") {
		var v int64
		fmt.Sscanf(s, "%dGi", &v)
		return v * 1024 * 1024 * 1024
	}
	var v int64
	fmt.Sscanf(s, "%d", &v)
	return v
}

func getNodeRAM() (used int64, total int64) {
	resp, err := k8sRequest("GET", "/api/v1/nodes", nil)
	if err != nil {
		return 0, 0
	}
	defer resp.Body.Close()
	var nodes struct {
		Items []struct {
			Status struct {
				Capacity map[string]string `json:"capacity"`
			} `json:"status"`
		} `json:"items"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&nodes); err != nil {
		return 0, 0
	}
	for _, n := range nodes.Items {
		total += parseK8sMemory(n.Status.Capacity["memory"])
	}

	resp2, err := k8sRequest("GET", "/apis/metrics.k8s.io/v1beta1/nodes", nil)
	if err != nil {
		return 0, total
	}
	defer resp2.Body.Close()
	var metrics struct {
		Items []struct {
			Usage struct {
				Memory string `json:"memory"`
			} `json:"usage"`
		} `json:"items"`
	}
	if err := json.NewDecoder(resp2.Body).Decode(&metrics); err != nil {
		return 0, total
	}
	for _, m := range metrics.Items {
		used += parseK8sMemory(m.Usage.Memory)
	}
	return used, total
}

func handleIndex(w http.ResponseWriter, r *http.Request) {
	data, _ := staticFiles.ReadFile("index.html")
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	w.Write(data)
}

func handleGetServices(w http.ResponseWriter, r *http.Request) {
	if r.Method != "GET" {
		http.Error(w, "Method not allowed", 405)
		return
	}

	deployments := listAllWorkloads()
	podMetrics := getPodMetricsAll()
	ramUsed, ramTotal := getNodeRAM()

	// Build set of deployment keys for RAM matching
	depKeys := make(map[string]bool)
	for _, d := range deployments {
		if !isHidden(d.Metadata.Namespace) {
			depKeys[d.Metadata.Namespace+"/"+d.Metadata.Name] = true
		}
	}
	ramMap := matchRAMToDeployments(podMetrics, depKeys)

	var statuses []ServiceStatus
	for _, d := range deployments {
		ns := d.Metadata.Namespace
		if isHidden(ns) {
			continue
		}
		replicas := 1
		if d.Spec.Replicas != nil {
			replicas = *d.Spec.Replicas
		}
		statuses = append(statuses, ServiceStatus{
			DisplayName: deploymentDisplayName(d.Metadata.Name),
			Name:        d.Metadata.Name,
			Namespace:   ns,
			Group:       groupName(ns),
			Kind:        d.Kind,
			CanStop:     !isNoStop(ns, d.Metadata.Name),
			Replicas:    replicas,
			Ready:       d.Status.ReadyReplicas > 0,
			RAMBytes:    ramMap[ns+"/"+d.Metadata.Name],
		})
	}

	// Sort by group then name
	sort.Slice(statuses, func(i, j int) bool {
		if statuses[i].Group != statuses[j].Group {
			return statuses[i].Group < statuses[j].Group
		}
		return statuses[i].Name < statuses[j].Name
	})

	resp := ServicesResponse{
		Services: statuses,
		RAMUsed:  ramUsed,
		RAMTotal: ramTotal,
	}
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(resp)
}

func handleScaleService(w http.ResponseWriter, r *http.Request) {
	if r.Method != "POST" {
		http.Error(w, "Method not allowed", 405)
		return
	}
	var req ScaleRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		http.Error(w, `{"error":"invalid request"}`, 400)
		return
	}
	if req.Replicas < 0 || req.Replicas > 1 {
		http.Error(w, `{"error":"replicas must be 0 or 1"}`, 400)
		return
	}
	if isHidden(req.Namespace) {
		http.Error(w, `{"error":"namespace not managed"}`, 403)
		return
	}
	if req.Replicas == 0 && isNoStop(req.Namespace, req.Name) {
		http.Error(w, `{"error":"this service cannot be stopped"}`, 403)
		return
	}

	err := scaleDeployment(req.Namespace, req.Name, req.Replicas)
	if err != nil {
		w.WriteHeader(500)
		json.NewEncoder(w).Encode(map[string]string{"error": err.Error()})
		return
	}
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(map[string]string{"status": "ok"})
}

func handleScaleGroup(w http.ResponseWriter, r *http.Request) {
	if r.Method != "POST" {
		http.Error(w, "Method not allowed", 405)
		return
	}
	var req GroupScaleRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		http.Error(w, `{"error":"invalid request"}`, 400)
		return
	}
	if req.Replicas < 0 || req.Replicas > 1 {
		http.Error(w, `{"error":"replicas must be 0 or 1"}`, 400)
		return
	}

	deployments := listAllWorkloads()
	var matched []k8sWorkload
	for _, d := range deployments {
		if groupName(d.Metadata.Namespace) == req.Group {
			matched = append(matched, d)
		}
	}
	if len(matched) == 0 {
		http.Error(w, `{"error":"unknown group"}`, 404)
		return
	}

	if req.Replicas == 0 {
		for i := len(matched) - 1; i >= 0; i-- {
			ns := matched[i].Metadata.Namespace
			name := matched[i].Metadata.Name
			if isNoStop(ns, name) {
				continue
			}
			if err := scaleDeployment(ns, name, 0); err != nil {
				log.Printf("Error stopping %s/%s: %v", ns, name, err)
			}
		}
	} else {
		for _, d := range matched {
			if err := scaleDeployment(d.Metadata.Namespace, d.Metadata.Name, 1); err != nil {
				log.Printf("Error starting %s/%s: %v", d.Metadata.Namespace, d.Metadata.Name, err)
			}
		}
	}

	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(map[string]string{"status": "ok"})
}

func findWorkloadKind(ns, name string) string {
	workloads := listAllWorkloads()
	for _, w := range workloads {
		if w.Metadata.Namespace == ns && w.Metadata.Name == name {
			return w.Kind
		}
	}
	return "Deployment"
}

// PausedAnnotation marks a workload as user-paused so setup services don't
// resurrect it on rebuild. `service-scaledown` honors it.
const PausedAnnotation = "homelab.k8s/user-paused"

func patchPausedAnnotation(ns, resource, name string, paused bool) error {
	var value string
	if paused {
		value = `"true"`
	} else {
		value = "null"
	}
	payload := fmt.Sprintf(`{"metadata":{"annotations":{"%s":%s}}}`, PausedAnnotation, value)
	resp, err := k8sRequest("PATCH",
		fmt.Sprintf("/apis/apps/v1/namespaces/%s/%s/%s", ns, resource, name),
		strings.NewReader(payload))
	if err != nil {
		return fmt.Errorf("annotation patch error: %w", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode >= 300 {
		body, _ := io.ReadAll(resp.Body)
		return fmt.Errorf("annotation failed (%d): %s", resp.StatusCode, string(body))
	}
	return nil
}

func scaleDeployment(ns, name string, replicas int) error {
	kind := findWorkloadKind(ns, name)

	mu.Lock()
	defer mu.Unlock()

	resource := "deployments"
	if kind == "StatefulSet" {
		resource = "statefulsets"
	} else if kind == "DaemonSet" {
		resource = "daemonsets"
	}

	if kind == "DaemonSet" {
		var payload string
		if replicas == 0 {
			payload = `{"spec":{"template":{"spec":{"nodeSelector":{"non-existing":"true"}}}}}`
		} else {
			payload = `{"spec":{"template":{"spec":{"nodeSelector":null}}}}`
		}
		resp, err := k8sRequest("PATCH",
			fmt.Sprintf("/apis/apps/v1/namespaces/%s/daemonsets/%s", ns, name),
			strings.NewReader(payload))
		if err != nil {
			return fmt.Errorf("k8s API error: %w", err)
		}
		defer resp.Body.Close()
		if resp.StatusCode >= 300 {
			body, _ := io.ReadAll(resp.Body)
			return fmt.Errorf("scale failed (%d): %s", resp.StatusCode, string(body))
		}
	} else {
		payload := fmt.Sprintf(`{"spec":{"replicas":%d}}`, replicas)
		resp, err := k8sRequest("PATCH",
			fmt.Sprintf("/apis/apps/v1/namespaces/%s/%s/%s/scale", ns, resource, name),
			strings.NewReader(payload))
		if err != nil {
			return fmt.Errorf("k8s API error: %w", err)
		}
		defer resp.Body.Close()
		if resp.StatusCode >= 300 {
			body, _ := io.ReadAll(resp.Body)
			return fmt.Errorf("scale failed (%d): %s", resp.StatusCode, string(body))
		}
	}

	if err := patchPausedAnnotation(ns, resource, name, replicas == 0); err != nil {
		log.Printf("Service %s/%s annotation update failed: %v", ns, name, err)
	}

	action := "stopped"
	if replicas > 0 {
		action = "started"
	}
	log.Printf("Service %s/%s (%s) %s", ns, name, kind, action)
	return nil
}

func restartDeployment(ns, name string) error {
	kind := findWorkloadKind(ns, name)

	mu.Lock()
	defer mu.Unlock()
	resource := "deployments"
	if kind == "StatefulSet" {
		resource = "statefulsets"
	} else if kind == "DaemonSet" {
		resource = "daemonsets"
	}

	timestamp := time.Now().Format(time.RFC3339)
	payload := fmt.Sprintf(`{"spec":{"template":{"metadata":{"annotations":{"kubectl.kubernetes.io/restartedAt":"%s"}}}}}`, timestamp)
	resp, err := k8sRequest("PATCH",
		fmt.Sprintf("/apis/apps/v1/namespaces/%s/%s/%s", ns, resource, name),
		strings.NewReader(payload))
	if err != nil {
		return fmt.Errorf("k8s API error: %w", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode >= 300 {
		body, _ := io.ReadAll(resp.Body)
		return fmt.Errorf("restart failed (%d): %s", resp.StatusCode, string(body))
	}
	log.Printf("Service %s/%s (%s) restarted", ns, name, kind)
	return nil
}

func handleRestartService(w http.ResponseWriter, r *http.Request) {
	if r.Method != "POST" {
		http.Error(w, "Method not allowed", 405)
		return
	}
	var req ScaleRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		http.Error(w, `{"error":"invalid request"}`, 400)
		return
	}
	if isHidden(req.Namespace) {
		http.Error(w, `{"error":"namespace not managed"}`, 403)
		return
	}
	err := restartDeployment(req.Namespace, req.Name)
	if err != nil {
		w.WriteHeader(500)
		json.NewEncoder(w).Encode(map[string]string{"error": err.Error()})
		return
	}
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(map[string]string{"status": "ok"})
}

func handlePing(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Access-Control-Allow-Origin", "*")
	w.Header().Set("Access-Control-Allow-Methods", "GET, HEAD, OPTIONS")

	if r.Method == "OPTIONS" {
		w.WriteHeader(200)
		return
	}
	if r.Method != "GET" && r.Method != "HEAD" {
		http.Error(w, "Method not allowed", 405)
		return
	}
	parts := strings.Split(strings.TrimPrefix(r.URL.Path, "/api/ping/"), "/")
	if len(parts) != 2 || parts[0] == "" || parts[1] == "" {
		http.Error(w, "Not found", 404)
		return
	}
	ns, name := parts[0], parts[1]

	resp, err := k8sRequest("GET", fmt.Sprintf("/apis/apps/v1/namespaces/%s/deployments/%s", ns, name), nil)
	if err != nil {
		w.WriteHeader(503)
		fmt.Fprintf(w, "error")
		return
	}
	defer resp.Body.Close()
	if resp.StatusCode != 200 {
		w.WriteHeader(503)
		fmt.Fprintf(w, "not found")
		return
	}
	var result struct {
		Spec struct {
			Replicas *int `json:"replicas"`
		} `json:"spec"`
		Status struct {
			ReadyReplicas int `json:"readyReplicas"`
		} `json:"status"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&result); err != nil {
		w.WriteHeader(503)
		fmt.Fprintf(w, "error")
		return
	}
	replicas := 1
	if result.Spec.Replicas != nil {
		replicas = *result.Spec.Replicas
	}
	if replicas == 0 || result.Status.ReadyReplicas == 0 {
		w.WriteHeader(503)
		fmt.Fprintf(w, "stopped")
		return
	}
	w.WriteHeader(200)
	fmt.Fprintf(w, "running")
}

func main() {
	loadConfig()

	http.HandleFunc("/", handleIndex)
	http.HandleFunc("/api/services", handleGetServices)
	http.HandleFunc("/api/services/scale", handleScaleService)
	http.HandleFunc("/api/services/restart", handleRestartService)
	http.HandleFunc("/api/groups/scale", handleScaleGroup)
	http.HandleFunc("/api/ping/", handlePing)

	log.Println("Service Manager listening on :8080")
	if err := http.ListenAndServe(":8080", nil); err != nil {
		log.Fatal(err)
	}
}
