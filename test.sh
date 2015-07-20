#!/usr/bin/env bash

set -e
set -u
set -o pipefail

# more bash-friendly output for jq
JQ="jq --raw-output --exit-status"

deploy_image() {

    docker login -u $DOCKER_USERNAME -p $DOCKER_PASS -e $DOCKER_EMAIL
    docker push bellkev/ecs-demo:$CIRCLE_SHA1 | cat # workaround progress weirdness

}

# reads $CIRCLE_SHA1, $host_port
# sets $task_def
make_task_def() {

    task_template='[
	{
	    "name": "uwsgi",
	    "image": "bellkev/ecs-demo:%s",
	    "essential": true,
	    "memory": 200,
	    "cpu": 10
	},
	{
	    "name": "nginx",
	    "links": [
		"uwsgi"
	    ],
	    "image": "bellkev/nginx-base:stable",
	    "portMappings": [
		{
		    "containerPort": 8000,
		    "hostPort": %s
		}
	    ],
	    "cpu": 10,
	    "memory": 200,
	    "essential": true
	}
    ]'

    task_def=$(printf "$task_template" $CIRCLE_SHA1 $host_port)

}

# reads $family
# sets $revision
register_definition() {

    if revision=$(aws ecs register-task-definition --container-definitions "$task_def" --family $family | $JQ '.taskDefinition.taskDefinitionArn'); then
        echo "Revision: $revision"
    else
        echo "Failed to register task definition"
        return 1
    fi

}

# sets $test_url
deploy_single() {

    host_port=0
    family="circle-ecs-single"

    make_task_def
    register_definition

    run_response=$(aws ecs run-task --cluster circle-ecs --task-definition $revision --count 1)
    if task=$(echo "$run_response" | $JQ '.tasks[0].taskArn'); then
        echo "Task: $task"
    else
        echo "Failed to run task:"
        echo "$run_response"
        return 1
    fi
    for attempt in {1..30}; do
        describe_response=$(aws ecs describe-tasks --cluster circle-ecs --tasks $task)
        if instance=$(echo "$describe_response" | $JQ '.tasks[0].containerInstanceArn') \
                && host_port=$(echo "$describe_response" | $JQ '.tasks[0].containers | .[] | select(.name=="nginx") | .networkBindings[0].hostPort') \
                && ec2_id=$(aws ecs describe-container-instances --cluster circle-ecs --container-instances $instance | $JQ '.containerInstances[0].ec2InstanceId') \
                && instance_ip=$(aws ec2 describe-instances --instance-ids $ec2_id | $JQ '.Reservations[0].Instances[0].PublicIpAddress'); then
            test_url="http://$instance_ip:$host_port"
            echo "Container URL: $test_url"
            return 0
        fi
        echo "Waiting for container to start..."
        sleep 5
    done
    echo "Container failed to become ready."
    return 1

}

# sets $test_url
deploy_cluster() {

    host_port=80
    family="circle-ecs-cluster"

    make_task_def
    register_definition
    if [[ $(aws ecs update-service --cluster circle-ecs --service circle-ecs-service --task-definition $revision | \
                   $JQ '.service.taskDefinition') != $revision ]]; then
        echo "Error updating service."
        return 1
    fi
    for attempt in {1..30}; do
        if stale=$(aws ecs describe-services --cluster circle-ecs --services circle-ecs-service | \
                       $JQ ".services[0].deployments | .[] | select(.taskDefinition != \"$revision\") | .taskDefinition"); then
            echo "Waiting for stale deployments:"
            echo "$stale"
            sleep 5
        else
            test_url="http://circle-ecs-1037150406.us-east-1.elb.amazonaws.com"
            echo "Cluster URL: $test_url"
            return 0
        fi
    done
    echo "Service update took too long."
    return 1
}

#reads $test_url
smoketest() {
    if curl --silent $test_url | grep "Hello"; then
        echo "Success!"
    else
        ret=$?
        echo "Failed. :("
        return $ret
    fi
}


deploy_image

case $1 in
    single) deploy_single ;;
    cluster) deploy_cluster ;;
esac

smoketest
