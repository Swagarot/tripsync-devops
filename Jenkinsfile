pipeline {
    agent { label 'k3s-agent' }

    environment {
        REGISTRY_USER = 'swagarot'
    }

    stages {
        stage('Verify tooling') {
            steps {
                sh 'docker --version'
                sh 'kubectl version --client'
                sh 'helm version'
            }
        }

        stage('Checkout app') {
            steps {
                dir('app') {
                    git branch: 'main',
                        credentialsId: '6daea266-02fa-4ffd-ad67-4ab97eec3938',
                        url: 'https://github.com/Swagarot/tripsync-app.git'
                }
            }
        }


                stage('Lint (Code Tests)') {
            parallel {
                stage('Helm chart') {
                    steps {
                        sh 'helm lint k8s-helm/tripsync'
                    }
                }
                stage('Backend (flake8)') {
                    steps {
                        sh '''
                            docker run --rm -u $(id -u):$(id -g) -e HOME=/tmp \
                              -v "$PWD/app/backend:/src" -w /src python:3.11-slim \
                              sh -c "pip install --user -q flake8 && python -m flake8 . --max-line-length=120"
                        '''
                    }
                }
                stage('Frontend (eslint)') {
                    steps {
                        sh '''
                            docker run --rm -u $(id -u):$(id -g) -e HOME=/tmp \
                              -v "$PWD/app/frontend:/src" -w /src node:20-alpine \
                              sh -c "npm ci && npm run lint"
                        '''
                    }
                }
            }
        }

        stage('Set image tag') {
            steps {
                script {
                    env.IMAGE_TAG = sh(
                        script: 'git -C app rev-parse --short HEAD',
                        returnStdout: true
                    ).trim()
                    echo "Image tag: ${env.IMAGE_TAG}"
                }
            }
        }

        stage('Build images') {
            steps {
                sh '''
                    docker build -t $REGISTRY_USER/tripsync-backend:$IMAGE_TAG app/backend
                    docker build -t $REGISTRY_USER/tripsync-frontend:$IMAGE_TAG app/frontend
                '''
            }
        }

        stage('Push images') {
            steps {
                withCredentials([usernamePassword(
                    credentialsId: 'dockerhub-creds',
                    usernameVariable: 'DH_USER',
                    passwordVariable: 'DH_TOKEN')]) {
                    sh '''
                        echo "$DH_TOKEN" | docker login -u "$DH_USER" --password-stdin
                        docker push $REGISTRY_USER/tripsync-backend:$IMAGE_TAG
                        docker push $REGISTRY_USER/tripsync-frontend:$IMAGE_TAG
                    '''
                }
            }
        }

        stage('Deploy') {
            steps {
                sh '''
                    helm upgrade tripsync k8s-helm/tripsync -n default \
                      --set-string backend.image.tag=$IMAGE_TAG \
                      --set-string frontend.image.tag=$IMAGE_TAG \
                      --atomic --timeout 3m
                    kubectl get pods -n tripsync
                '''
            }
        }
    }

    post {
        always {
            sh 'docker logout || true'
        }
    }
}