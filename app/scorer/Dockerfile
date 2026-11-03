# AWS's official Lambda base image: Python plus the Lambda runtime
FROM public.ecr.aws/lambda/python:3.13

COPY scoring.py store.py app.py generator.py enricher.py ${LAMBDA_TASK_ROOT}/

# "file.function" Lambda calls for each request
CMD ["app.handler"]
