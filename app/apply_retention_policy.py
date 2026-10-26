import re
import shutil
import logging
import argparse
import yaml
from datetime import datetime
from pathlib import Path
from retention_rules import PolicyBuilder
from dataclasses import dataclass
from pydantic import BaseModel
from pydantic_settings import SettingsConfigDict

logging.basicConfig(level=logging.INFO, format="%(asctime)s - %(levelname)s - %(message)s")


@dataclass
class MyFileFolderPath:
    file_path: Path
    timestamp: datetime

    def __init__(self, file_path):
        self.file_path = file_path
        self.timestamp = None
        self.extract_timestamp()

    def extract_timestamp(self):
        try:
            match = filename_regex.search(self.file_path.name)
        # catch exception if filename_regex is not defined
        except NameError as e:
            logging.error(f"filename_regex is not defined: {e}")
            return
        except Exception as e:
            logging.error(f"Failed to extract timestamp from {self.file_path}: {e}")
            return
        
        if match:
            date_str, time_str = match.groups()
            self.timestamp = datetime.strptime(f"{date_str} {time_str}", "%Y%m%d %H%M%S")


class RetentionPolicySettings(BaseModel):
    filename_pattern: str
    retention_policy: dict

    class Config:
        model_config = SettingsConfigDict(env_file=None, env_file_encoding=None)

def delete_entry(path: Path, base: Path) -> bool:
    """Delete one entry that sits directly inside `base`. Returns True if deleted.

    Symlinks are unlinked and never followed. Folders are removed recursively
    (shutil.rmtree does not follow symlinks inside the tree either).
    """
    if path.parent.absolute() != base.absolute():
        logging.error(f"Refusing to delete {path}: not directly inside {base}")
        return False
    if path.is_symlink():
        path.unlink()
    elif path.is_dir():
        shutil.rmtree(path)
    elif path.is_file():
        path.unlink()
    else:
        return False
    return True


# Parse input arguments
parser = argparse.ArgumentParser(description="Apply retention policy to files and directories in a folder.")
parser.add_argument("--dry_run", action="store_true", help="Perform a dry run without deleting any files or directories.")
parser.add_argument("folder_path", type=str, help="Path to the folder containing files and directories.")
parser.add_argument("config_path", type=str, default="./retention_config.yml", help="Path to the YAML configuration file.")
args = parser.parse_args()

# Load configuration from YAML file
with open(args.config_path, 'r') as file:
    config_data = yaml.safe_load(file)
settings = RetentionPolicySettings(**config_data)

# Define folder path
folder_path = Path(args.folder_path)

# Compile filename regex
filename_regex = re.compile(settings.filename_pattern)

# Define retention policy using PolicyBuilder
policy = PolicyBuilder().build(settings.retention_policy)

# Get a list of all files and directories in the folder
files = folder_path.iterdir()

# Create a list to store file and directory paths with timestamps
list_of_files = []

# Iterate over each item and extract timestamp
for item in files:
    if item.is_file() or item.is_dir():
        logging.debug(f"Processing: {item}")
        myfileitem = MyFileFolderPath(file_path=item)
        if myfileitem.timestamp is None:
            logging.error(f"Failed to extract timestamp from {item}")
            continue

        logging.debug(f"Adding file ...")
        list_of_files.append(myfileitem)

# Sort the list of files by timestamp
list_of_files.sort(key=lambda x: x.timestamp)

# Apply the retention policy to decide which items to retain
results = policy.check_retention(list_of_files, key=lambda x: x.timestamp)

# Delete items that should not be retained
print("")
count = 0
for result in results:
    if not result.retain:
        if args.dry_run:
            logging.info(f"Would delete: {result.item.file_path.name}")
        else:
            if delete_entry(result.item.file_path, folder_path):
                logging.info(f"Deleted: {result.item.file_path.name}")
                count += 1

if args.dry_run:
    for result in results:
        if result.retain:
            logging.info(f"Would retain: {result.item.file_path.name}")
    

logging.info(f"Deleted {count} items.")
logging.info("Retention policy applied successfully.")
