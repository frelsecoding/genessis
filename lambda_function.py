import json
import base64
import boto3
import os
import uuid
from requests_toolbelt.multipart import decoder

s3 = boto3.client('s3')
S3_BUCKET_NAME = os.environ.get('S3_BUCKET_NAME')

def lambda_handler(event, context):
    print("Uploader Lambda event received.")

    if not S3_BUCKET_NAME:
        print("Error: S3_BUCKET_NAME environment variable not set.")
        return {
            'statusCode': 500,
            'headers': {'Content-Type': 'application/json', 'Access-Control-Allow-Origin': '*'},
            'body': json.dumps({'error': 'Server configuration error: S3_BUCKET_NAME missing'})
        }

    try:
        headers = {k.lower(): v for k, v in event.get('headers', {}).items()}
        content_type = headers.get('content-type')

        if not content_type:
            print(f"Error: Missing content-type header.")
            return {
                'statusCode': 400,
                'headers': {'Content-Type': 'application/json', 'Access-Control-Allow-Origin': '*'},
                'body': json.dumps({'error': "Missing content-type header."})
            }

        body_str = event.get('body', '')
        if event.get('isBase64Encoded', False):
            body_bytes = base64.b64decode(body_str)
        else:
            # If not base64 encoded, it might be binary passed directly or incorrectly encoded.
            # For multipart/form-data, requests_toolbelt decoder expects bytes.
            # Attempting latin-1 is a common way to handle potential misinterpretations of binary as string.
            print("Warning: Body was not Base64 encoded. Assuming binary data passed as string, encoding to latin-1.")
            body_bytes = body_str.encode('latin-1') # Convert string to bytes

        multipart_data = decoder.MultipartDecoder(body_bytes, content_type)

        file_content_bytes = None
        original_filename = "unknown_file"
        device_id_value = None # To store the value from the 'deviceID' form field
        model_title_value = None # To store the value from the 'modelTitle' form field

        for part in multipart_data.parts:
            content_disposition_bytes = part.headers.get(b'content-disposition')
            part_name = None

            if content_disposition_bytes:
                disposition_str = content_disposition_bytes.decode('utf-8', errors='ignore')
                name_parts = disposition_str.split('name="')
                if len(name_parts) > 1:
                    part_name = name_parts[1].split('"')[0]

                if part_name == "audioFile":
                    file_content_bytes = part.content
                    fn_parts = disposition_str.split('filename="')
                    if len(fn_parts) > 1:
                        original_filename = fn_parts[1].split('"')[0]
                    else:
                        original_filename = "untitled_audio" # Default if filename not in disposition
                    print(f"Found 'audioFile' part. Filename: '{original_filename}', Content length: {len(file_content_bytes) if file_content_bytes else 0}")

                elif part_name == "deviceID":
                    device_id_value = part.text
                    print(f"Found 'deviceID' part. Value: '{device_id_value}'")
                
                elif part_name == "modelTitle": # Changed from modelSelection to modelTitle
                    model_title_value = part.text
                    print(f"Found 'modelTitle' part. Value: '{model_title_value}'")

        if file_content_bytes is None:
            print("Error: 'audioFile' form field not found in multipart form-data.")
            return {
                'statusCode': 400,
                'headers': {'Content-Type': 'application/json', 'Access-Control-Allow-Origin': '*'},
                'body': json.dumps({'error': "Field 'audioFile' missing in form-data."})
            }

        safe_original_filename = "".join(c if c.isalnum() or c in ('.', '_', '-') else '_' for c in original_filename) if original_filename else "uploaded_file"
        if not safe_original_filename.strip('._-'): safe_original_filename = "file" # Ensure filename is not just dots/underscores/hyphens
        
        # Ensure a unique S3 object key
        unique_id = str(uuid.uuid4())
        s3_object_key = f"uploads/{unique_id}/{safe_original_filename}"


        s3_upload_metadata = {
            'original-filename': safe_original_filename # Store the sanitized original filename
        }
        if device_id_value:
            s3_upload_metadata['device-id'] = device_id_value
        else:
            print("Warning: 'deviceID' not provided. It will not be set in S3 metadata.")
            
        if model_title_value:
            s3_upload_metadata['model-title'] = model_title_value
        else:
            print("Warning: 'modelTitle' not provided. It will not be set in S3 metadata.")
            # You could set a default model if needed, e.g., s3_upload_metadata['model-title'] = "default_model"

        print(f"Attempting to upload to S3. Bucket: {S3_BUCKET_NAME}, Key: {s3_object_key}, Metadata: {s3_upload_metadata}")
        s3.put_object(
            Bucket=S3_BUCKET_NAME,
            Key=s3_object_key,
            Body=file_content_bytes,
            Metadata=s3_upload_metadata
        )
        print(f"File uploaded to S3: s3://{S3_BUCKET_NAME}/{s3_object_key} with metadata: {s3_upload_metadata}")

        return {
            'statusCode': 200,
            'headers': {
                'Content-Type': 'application/json',
                'Access-Control-Allow-Origin': '*'
            },
            'body': json.dumps({
                'message': 'File uploaded successfully, processing initiated.',
                's3_bucket': S3_BUCKET_NAME,
                's3_key': s3_object_key,
                'original_filename_stored': safe_original_filename,
                'device_id_stored': device_id_value if device_id_value else "Not provided",
                'model_title_stored': model_title_value if model_title_value else "Not provided"
            })
        }

    except decoder.ImproperBodyPartContentException as e_improper:
        print(f"Error decoding multipart body (ImproperBodyPartContentException): {e_improper}")
        # import traceback # Already imported below if needed for more detail
        # traceback.print_exc()
        return {'statusCode': 400, 'headers': {'Content-Type': 'application/json', 'Access-Control-Allow-Origin': '*'}, 'body': json.dumps({'error': 'Invalid multipart/form-data content.', 'details': str(e_improper)})}
    except UnicodeDecodeError as e_unicode: # Specific to header decoding issues usually
        print(f"Error decoding header (UnicodeDecodeError): {e_unicode}")
        # import traceback
        # traceback.print_exc()
        return {'statusCode': 400, 'headers': {'Content-Type': 'application/json', 'Access-Control-Allow-Origin': '*'}, 'body': json.dumps({'error': 'Invalid header encoding in multipart/form-data.', 'details': str(e_unicode)})}
    except Exception as e:
        print(f"Error in Uploader Lambda: {type(e).__name__} - {e}")
        import traceback
        traceback.print_exc()
        return {
            'statusCode': 500,
            'headers': {'Content-Type': 'application/json', 'Access-Control-Allow-Origin': '*'},
            'body': json.dumps({'error': 'Internal server error during upload', 'details': str(e)})
        }
