from locust import HttpUser, task, between

class HeavyTrafficUser(HttpUser):
    wait_time = between(0.1, 0.5)

    @task(5)
    def read_entries(self):
        self.client.get("/api/data/")

    @task(1)
    def write_entry(self):
        self.client.post("/api/data", json={
            "name": "Locust Bot",
            "email": "bot@test.com",
            "message": "Testing Slave Read Status"
        })

