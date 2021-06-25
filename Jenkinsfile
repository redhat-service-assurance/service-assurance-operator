#!/usr/bin/env groovy

def namespace = env.BUILD_TAG.toLowerCase()

podTemplate(containers: [
    containerTemplate(
        name: 'exec',
        image: 'image-registry.openshift-image-registry.svc:5000/ci/jenkins-agent:latest',
        command: 'sleep',
        args: 'infinity',
        alwaysPullImage: true
    )],
    serviceAccount: 'jenkins-cloudops'

) {
    node(POD_LABEL) {
        container('exec') {
            dir('service-telemetry-operator') {
                stage ('Clone Upstream') {
                    checkout scm
                }
                stage ('Create project') {
                    openshift.withCluster(){
                        openshift.newProject(namespace)
                    }
                }
                stage('Deploy STF') {
                    catchError(buildResult: 'SUCCESS', stageResult: 'FAILURE') {
                        ansiColor('xterm') {
                            ansiblePlaybook(
                                playbook: 'build/run-ci.yaml',
                                colorized: true,
                                extraVars: [
                                    "namespace": namespace,
                                    "__local_build_enabled": "true",
                                    "__service_telemetry_snmptraps_enabled": "true",
                                    "__service_telemetry_storage_ephemeral_enabled": "true"
                                ]
                            )
                        }
                    }
                }
                stage('Run Smoketest') {
                    catchError(buildResult: 'SUCCESS', stageResult: 'FAILURE') {
                        sh 'OCP_PROJECT="${namespace}" ./tests/smoketest/smoketest.sh'
                    }
                }
                stage('Cleanup') {
                    openshift.withCluster(){
                        openshift.selector("project/${namespace}").delete()
                    }
                }
            }
        }
    }
}

