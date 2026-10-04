pipeline {
    agent { label 'k3s-agent' }

    stages {
        stage('Verify tooling') {
            steps {
                sh 'docker --version'
                sh 'kubectl version --client'
                sh 'helm version'
            }
        }

        stage('Verify cluster access') {
            steps {
                sh 'kubectl get nodes'
            }
        }
    }
}