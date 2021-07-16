#!/usr/bin/env groovy

// can't just use BUILD_TAG because qdr operator limits name of resources to 60 chars
def namespace = env.JOB_BASE_NAME + '-' + env.BUILD_NUMBER
namespace = namespace.toLowerCase()

podTemplate(containers: [
    containerTemplate(
        cloud: 'openshift',
        name: 'exec',
        image: 'image-registry.openshift-image-registry.svc:5000/ci/jenkins-agent:latest',
        command: 'sleep',
        args: 'infinity',
        alwaysPullImage: true
    )],
    serviceAccount: 'jenkins-operator-cloudops'

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

